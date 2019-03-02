{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Build
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
-- | Simple build system for packages
--
-------------------------------------------------------------------------------


module IDE.Build (
    MakeSettings(..),
    MakeOp(..),
    moNoOp,
    makePackages,
    defaultMakeSettings
) where

import Prelude ()
import Prelude.Compat
import IDE.Core.State
       (triggerEventIDE_, IDEAction, Project(..), ipdPackageId,
        ipdDepends, IDEPackage(..))
import IDE.Gtk.State (postAsyncIDE)
import qualified Data.Map as Map
       (lookup, fromList)
import Data.Graph
       (edges, topSort, graphFromEdges, Vertex, Graph,
        transposeG)
import Distribution.Package (pkgVersion, pkgName, Dependency(..))
import Data.List (deleteFirstsBy, nubBy, find)
import Distribution.Version (withinRange)
import Data.Maybe (fromMaybe, mapMaybe)
import IDE.Package
       (packageClean', buildPackage,
        packageTest', packageDoc', packageBench', packageInstall')
import IDE.Core.Types
       (ipdPackageName, pjPackages, IDEEvent(..), Prefs(..))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Arrow ((***))
import Data.Text (Text)
import Distribution.Text (disp)
import qualified Data.Text as T (pack, unpack)
import System.Log.Logger (debugM)
import qualified Control.Arrow as Arrow (Arrow(..))
import qualified Data.Function as F (on)

-- import Debug.Trace (trace)
trace :: a -> b -> b
trace _a b = b

-- * Exported

data MakeSettings = MakeSettings {
    msMakeMode                       :: Bool,
    msSingleBuildWithoutLinking      :: Bool,
    msSaveAllBeforeBuild             :: Bool,
    msBackgroundBuild                :: Bool,
    msMakeDocs                       :: Bool,
    msRunUnitTests                   :: Bool,
    msRunBenchmarks                  :: Bool,
    msJumpToWarnings                 :: Bool,
    msDontInstallLast                :: Bool,
    msSuccessAction                  :: IDEAction}

-- | Take make settings from preferences
defaultMakeSettings :: Prefs -> MakeSettings
defaultMakeSettings Prefs{..} = MakeSettings  {
    msMakeMode                       = makeMode,
    msSingleBuildWithoutLinking      = singleBuildWithoutLinking,
    msSaveAllBeforeBuild             = saveAllBeforeBuild,
    msBackgroundBuild                = backgroundBuild,
    msMakeDocs                       = makeDocs,
    msRunUnitTests                   = runUnitTests,
    msRunBenchmarks                  = runBenchmarks,
    msJumpToWarnings                 = jumpToWarnings,
    msDontInstallLast                = dontInstallLast,
    msSuccessAction                  = return ()}

-- | a make operation
data MakeOp =
    MoBuild
    | MoTest
    | MoBench
    | MoInstall
    | MoClean
    | MoDocu
    | MoOther Text
    | MoMetaInfo -- rebuild meta info for workspace
    | MoComposed [MakeOp]
    deriving (Eq,Ord,Show)

moNoOp :: MakeOp
moNoOp = MoComposed []

-- | The interface to the build system
-- Consumes settings, a list of targets and a the operation to perform.
-- The firstOp will be applied to the first target
-- The restOp will be applied to all other targets
-- The finishOp will be applied to the last target after any op succeeded,
-- but it is applied after restOp has been tried on the last target
makePackages ::  MakeSettings -> [(Project, [IDEPackage])] -> MakeOp -> MakeOp -> MakeOp -> IDEAction
makePackages ms targets firstOp restOp  finishOp = do
    liftIO $ debugM "leksah" $ "makePackages : "
            <> "targets = " <> show (map (pjFile *** map ipdPackageName) targets)
            <> ", fistOp = " <> show firstOp
            <> ", restOp = " <> show restOp
    let plan = constrMakeChain ms targets firstOp restOp finishOp
    liftIO $ debugM "leksah" $ "makePackages : makeChain : " <> show plan
    doBuildChain ms plan

-- ** Types

type MakeGraph = [(IDEPackage, [IDEPackage])]

data Chain alpha beta  =
    Chain {
        mcAction :: alpha,
        mcEle    :: beta,
        mcPos    :: Chain alpha beta,
        mcNeg    :: Maybe (Chain alpha beta)}
    | EmptyChain
    deriving Show

-- ** Functions
-- | Construct a make chain for a package,
-- which is a plan of the build to perform.
-- Consumes settings, the workspace and a list of targets.
-- The first op is applied to the first target.

constrMakeChain :: MakeSettings -> [(Project, [IDEPackage])] -> MakeOp ->
    MakeOp -> MakeOp -> Chain MakeOp (Project, [IDEPackage])
-- No more targets
constrMakeChain _ [] _ _ _ = EmptyChain

constrMakeChain ms@MakeSettings{msMakeMode = makeMode}
                    targets firstOp restOp finishOp =
--    trace (T.unpack $ "topsorted: " <> showTopSorted topsorted)
    constrElem (map addTopSorted targets) ms
                    firstOp restOp finishOp False
  where
        depGraph packages | makeMode  = constrDepGraph packages
                          | otherwise = []
        addTopSorted (project, targets') = (project, targets', reverse $ topSortGraph $ constrParentGraph $ pjPackages project, depGraph $ pjPackages project)

-- Constructs a make chain
chainFor :: Project -> [IDEPackage] ->  MakeSettings -> MakeOp -> Chain MakeOp (Project, [IDEPackage])
                -> Maybe (Chain MakeOp (Project, [IDEPackage]))
                -> Chain MakeOp (Project, [IDEPackage])
chainFor project target settings (MoComposed [hdOp]) cont mbNegCont =
    chainFor project target settings hdOp cont mbNegCont
chainFor project target settings (MoComposed (hdOp:rest)) cont mbNegCont =
    chainFor project target settings hdOp (chainFor project target settings (MoComposed rest) cont mbNegCont)
        mbNegCont
chainFor project target _settings op cont mbNegCont = Chain {
        mcAction =  op,
        mcEle    = (project, target),
        mcPos    =  cont,
        mcNeg    =  mbNegCont}

equalOnCabalFile :: IDEPackage -> IDEPackage -> Bool
equalOnCabalFile = (==) `F.on` ipdCabalFile

-- Recursive building of a make chain
-- The first list of packages are the targets
-- The second list of packages is the topsorted graph of all deps of all targets
constrElem  :: [(Project, [IDEPackage], [IDEPackage], MakeGraph)] -> MakeSettings
    -> MakeOp -> MakeOp -> MakeOp -> Bool -> Chain MakeOp (Project, [IDEPackage])
constrElem [] _ _ _ _ _ = EmptyChain
constrElem ((project, currentTargets, tops, depGraph):rest) ms
    firstOp restOp finishOp doneAnything =
    case filter (\p -> ipdCabalFile p `elem` map ipdCabalFile currentTargets) tops of
        [] -> constrElem rest ms firstOp restOp finishOp doneAnything
        sorted@(current:_) ->
            let dependents = fromMaybe
                                (trace ("Build>>constrMakeChain: unknown package" ++ show current)
                                   [])
                                (Map.lookup (ipdCabalFile current) depMap)
                depMap = Map.fromList $ map (Arrow.first ipdCabalFile) depGraph
                withoutInstall = msDontInstallLast ms && all (equalOnCabalFile current) dependents
                filteredOps = case firstOp of
                                MoComposed l -> MoComposed (filter (/= MoInstall) l)
                                MoInstall    -> MoComposed []
                                other        -> other
            in trace ("constrElem1 deps: " ++ show dependents ++ " withoutInstall: " ++ show withoutInstall)
                $
                chainFor project sorted ms (if withoutInstall then filteredOps else firstOp)
                    (constrElem rest ms firstOp restOp finishOp doneAnything)
                    (Just $ if doneAnything
                                then chainFor project sorted ms finishOp EmptyChain Nothing
                                else EmptyChain)


-- | Performs the operations of a build chain
doBuildChain :: MakeSettings -> Chain MakeOp (Project, [IDEPackage]) -> IDEAction
doBuildChain ms EmptyChain = msSuccessAction ms
doBuildChain ms chain@Chain{mcAction = MoBuild} =
    postAsyncIDE $ buildPackage (msBackgroundBuild ms) (msJumpToWarnings ms) (not (msMakeMode ms) && msSingleBuildWithoutLinking ms)
        (mcEle chain) (constrCont ms (mcPos chain) (mcNeg chain))
doBuildChain ms chain@Chain{mcAction = MoDocu} =
    postAsyncIDE $ packageDoc' (msBackgroundBuild ms) (msJumpToWarnings ms) (mcEle chain) (constrCont ms (mcPos chain) (mcNeg chain))
doBuildChain ms chain@Chain{mcAction = MoTest} =
    postAsyncIDE $ packageTest' (msBackgroundBuild ms) (msJumpToWarnings ms) (mcEle chain) (constrCont ms (mcPos chain) (mcNeg chain))
doBuildChain ms chain@Chain{mcAction = MoBench} =
    postAsyncIDE $ packageBench' (msBackgroundBuild ms) (msJumpToWarnings ms) (mcEle chain) (constrCont ms (mcPos chain) (mcNeg chain))
doBuildChain ms chain@Chain{mcAction = MoInstall} =
    postAsyncIDE $ packageInstall' (mcEle chain) (constrCont ms (mcPos chain) (mcNeg chain))
doBuildChain ms chain@Chain{mcAction = MoClean} =
    postAsyncIDE $ packageClean' (mcEle chain) (constrCont ms (mcPos chain) (mcNeg chain))
doBuildChain _ms Chain{mcAction = MoMetaInfo} =
    postAsyncIDE $ triggerEventIDE_ (UpdateWorkspaceInfo False)
doBuildChain ms chain  = doBuildChain ms (mcPos chain)

constrCont
  :: MakeSettings
  -> Chain MakeOp (Project, [IDEPackage])
  -> Maybe (Chain MakeOp (Project, [IDEPackage]))
  -> Bool
  -> IDEAction
constrCont ms _pos (Just neg) False = doBuildChain ms neg
constrCont ms pos _ _ = doBuildChain ms pos

-- | Construct a dependency graph for a package
-- pointing to the packages the subject package depends on
constrParentGraph :: [IDEPackage] -> MakeGraph
constrParentGraph targets = trace (T.unpack $ "parentGraph : " <> showGraph parGraph) parGraph
  where
    parGraph = map (\ p -> (p,nubBy equalOnCabalFile $ mapMaybe (depToTarget targets)(ipdDepends p))) targets

-- | Construct a dependency graph for a package
-- pointing to the packages which depend on the subject package
constrDepGraph :: [IDEPackage] -> MakeGraph
constrDepGraph packages = trace (T.unpack $ "depGraph : " <> showGraph depGraph) depGraph
  where
    depGraph = reverseGraph (constrParentGraph packages)

showGraph :: MakeGraph -> Text
showGraph mg =
    T.pack $ show
        $ map (\(k, v) -> (k, map (disp . ipdPackageId) v)) mg

--showTopSorted :: [IDEPackage] -> Text
--showTopSorted = T.pack . show . map (disp .ipdPackageId)


-- | Calculates for every dependency a target (or not)

depToTarget :: [IDEPackage] -> Dependency -> Maybe IDEPackage
depToTarget list dep = find (doesMatch dep) list
        where
        doesMatch (Dependency name versionRange) thePack =
            name == pkgName (ipdPackageId thePack)
            &&  withinRange (pkgVersion (ipdPackageId thePack)) versionRange

reverseGraph :: MakeGraph -> MakeGraph
reverseGraph = withIndexGraph transposeG

topSortGraph :: MakeGraph -> [IDEPackage]
topSortGraph myGraph =  map ((\ (x,_,_)-> x) . lookup') $ topSort graph
  where
    (graph,lookup',_) = fromMyGraph myGraph

withIndexGraph :: (Graph -> Graph) -> MakeGraph -> MakeGraph
withIndexGraph idxOp myGraph = toMyGraph (idxOp graph) lookup'
  where
    (graph,lookup',_) = fromMyGraph myGraph

fromMyGraph :: MakeGraph -> (Graph, Vertex -> (IDEPackage, FilePath, [FilePath]), FilePath -> Maybe Vertex)
fromMyGraph graphList =
    graphFromEdges
        $ map (\(e,l)-> (e,ipdCabalFile e, map ipdCabalFile l))
            $ graphList ++ map (, []) missingEdges
  where
    mentionedEdges = nubBy equalOnCabalFile $ concatMap snd graphList
    missingEdges = deleteFirstsBy equalOnCabalFile mentionedEdges $ map fst graphList

toMyGraph :: Graph -> (Vertex -> (IDEPackage, FilePath, [FilePath])) -> MakeGraph
toMyGraph graph lookup' = foldr constr [] myEdges
  where
    constr (from,to) m = case lookup (ipdCabalFile from) (map (Arrow.first ipdCabalFile) m) of
                                Nothing -> (from, [to]):m
                                Just l -> (from, to : l):m
    myEdges              = map (lookItUp *** lookItUp) $ edges graph
    lookItUp             =  (\(e,_,_)-> e) . lookup'






