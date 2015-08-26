{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Distribution.Nixpkgs.Haskell.FromCabal ( fromGenericPackageDescription, fromPackageDescription ) where

import Control.Arrow ( second )
import Data.Maybe
import qualified Data.Set as Set
import Data.Set ( Set )
import Distribution.Compiler
import Distribution.Nixpkgs.Haskell
import qualified Distribution.Nixpkgs.Haskell as Nix
import Distribution.Nixpkgs.Haskell.Constraint
import Distribution.Nixpkgs.Haskell.FromCabal.License
import Distribution.Nixpkgs.Haskell.FromCabal.Name
import Distribution.Nixpkgs.Haskell.FromCabal.Normalize
import Distribution.Nixpkgs.Haskell.FromCabal.PostProcess
import qualified Distribution.Nixpkgs.Meta as Nix
import Distribution.Package
import Distribution.PackageDescription
import qualified Distribution.PackageDescription as Cabal
import Distribution.PackageDescription.Configuration
import Distribution.System
import Distribution.Text ( display )
import Distribution.Version
import Internal.Lens
import Language.Nix

type HaskellResolver = Dependency -> Bool
type NixpkgsResolver = Identifier -> Maybe Binding

fromGenericPackageDescription :: HaskellResolver -> NixpkgsResolver -> Platform -> CompilerInfo ->  FlagAssignment -> [Constraint] -> GenericPackageDescription -> Derivation
fromGenericPackageDescription haskellResolver nixpkgsResolver arch compiler flags constraints descr'' =
  case finalize haskellResolver of
    Left mismatch -> case finalize jailbrokenResolver of
                       Left missing -> case finalize (const True) of
                                         Left missing' -> error $ "finalizePackageDescription complains about missing dependencies \
                                                                  \even though we told it that everything exists: " ++ show missing'
                                         Right (descr,_) -> fromPackageDescription haskellResolver nixpkgsResolver mismatch missing flags descr
                       Right (descr,_) -> fromPackageDescription haskellResolver nixpkgsResolver mismatch [] flags descr
    Right (descr,_) -> fromPackageDescription haskellResolver nixpkgsResolver [] [] flags descr

  where
    -- We have to call the Cabal finalizer several times with different resolver functions, and this
    -- convenience function makes our code shorter.
    finalize :: HaskellResolver -> Either [Dependency] (PackageDescription,FlagAssignment)
    finalize resolver = finalizePackageDescription flags resolver arch compiler constraints descr'

    jailbrokenResolver :: HaskellResolver
    jailbrokenResolver (Dependency pkg _) = haskellResolver (Dependency pkg anyVersion)

    -- A variant of the cabal file that has all test suites enabled to ensure
    -- that their dependencies are recognized by finalizePackageDescription.
    descr' :: GenericPackageDescription
    descr' = descr'' { condTestSuites = flaggedTests }

    flaggedTests :: [(String, CondTree ConfVar [Dependency] TestSuite)]
    flaggedTests = map (second (mapTreeData enableTest)) (condTestSuites descr'')

    enableTest :: TestSuite -> TestSuite
    enableTest t = t { testEnabled = True }

fromPackageDescription :: HaskellResolver -> NixpkgsResolver -> [Dependency] -> [Dependency] -> FlagAssignment -> PackageDescription -> Derivation
fromPackageDescription haskellResolver nixpkgsResolver mismatchedDeps missingDeps flags (PackageDescription {..}) = normalize $ postProcess $ def
    & isLibrary .~ isJust library
    & pkgid .~ package
    & revision .~ xrev
    & isLibrary .~ isJust library
    & isExecutable .~ not (null executables)
    & extraFunctionArgs .~ mempty
    & libraryDepends .~ maybe mempty (convertBuildInfo . libBuildInfo) library
    & executableDepends .~ mconcat (map (convertBuildInfo . buildInfo) executables)
    & testDepends .~ mconcat (map (convertBuildInfo . testBuildInfo) testSuites)
    & configureFlags .~ mempty
    & cabalFlags .~ flags
    & runHaddock .~ True
    & jailbreak .~ (not (null mismatchedDeps && null missingDeps))
    & doCheck .~ True
    & testTarget .~ mempty
    & hyperlinkSource .~ True
    & enableSplitObjs .~ True
    & phaseOverrides .~ mempty
    & editedCabalFile .~ (if xrev > 0
                             then fromMaybe (error (display package ++ ": X-Cabal-File-Hash field is missing")) (lookup "X-Cabal-File-Hash" customFieldsPD)
                             else "")
    & metaSection .~ ( def
                     & Nix.homepage .~ homepage
                     & Nix.description .~ synopsis
                     & Nix.license .~ fromCabalLicense license
                     & Nix.platforms .~ mempty
                     & Nix.hydraPlatforms .~ mempty
                     & Nix.maintainers .~ mempty
                     & Nix.broken .~ not (null missingDeps)
                     )
  where
    xrev = maybe 0 read (lookup "x-revision" customFieldsPD)

    resolveInHackage :: Identifier -> Binding
    resolveInHackage i | (i^.ident) `elem` [ n | (Dependency (PackageName n) _) <- missingDeps ] = bindNull i
                       | otherwise = create binding (i, create path ["self",i])   -- TODO: "self" shouldn't be hardcoded.

    resolveInNixpkgs :: Identifier -> Binding
    resolveInNixpkgs i
      | i `elem` ["clang","lldb","llvm"] = create binding (i,create path ["self","llvmPackages",i])     -- TODO: evil!
      | otherwise                        = fromMaybe (bindNull i) (nixpkgsResolver i)

    resolveInHackageThenNixpkgs :: Identifier -> Binding
    resolveInHackageThenNixpkgs i | haskellResolver (Dependency (PackageName (i^.ident)) anyVersion) = resolveInHackage i
                                  | otherwise = resolveInNixpkgs i

    convertBuildInfo :: Cabal.BuildInfo -> Nix.BuildInfo
    convertBuildInfo Cabal.BuildInfo {..} = mempty
      & haskell .~ Set.fromList [ resolveInHackage (toNixName x) | (Dependency x _) <- targetBuildDepends ]
      & system .~ Set.fromList [ resolveInNixpkgs y | x <- extraLibs, y <- libNixName x ]
      & pkgconfig .~ Set.fromList [ resolveInNixpkgs y | Dependency (PackageName x) _ <- pkgconfigDepends, y <- libNixName x ]
      & tool .~ Set.fromList [ resolveInHackageThenNixpkgs y | Dependency (PackageName x) _ <- buildTools, y <- buildToolNixName x ]

bindNull :: Identifier -> Binding
bindNull i = create binding (i, create path ["null"])