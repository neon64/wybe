--  File     : LastCallAnalysis.hs
--  Author   : Chris Chamberlain
--  Purpose  : Transform proc bodies and their output arguments so that
--             more recursive algorithms can be tail-call optimised.
--  Copyright: (c) 2015-2022 Peter Schachte.  All rights reserved.
--  License  : Licensed under terms of the MIT license.  See the file
--           : LICENSE in the root directory of this project.
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}

module LastCallAnalysis (lastCallAnalyseMod, lastCallAnalyseProc) where
import AST
import qualified Data.List as List
import qualified UnivSet
import Options (LogSelection(LastCallAnalysis),
                optimisationEnabled, OptFlag(TailCallModCons))
import Util (sccElts, lift2)
import Data.Foldable (foldrM, foldlM)
import Data.List.Predicate (allUnique)
import Callers (getSccProcs)
import Data.Graph (SCC (AcyclicSCC, CyclicSCC))
import Control.Monad.State (StateT (runStateT), MonadTrans (lift), execStateT, execState, runState, MonadState (get, put), gets, modify, unless, MonadPlus (mzero))
import Control.Monad ( liftM, (>=>), when )
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Data.Binary.Get (remaining)

-- | Perform last call analysis on a single module.
-- Internally, we perform analysis bottom-up on proc SCCs.
lastCallAnalyseMod :: ModSpec -> Compiler ()
lastCallAnalyseMod thisMod = do
    reenterModule thisMod
    orderedProcs <- getSccProcs thisMod
    logLastCallAnalysis $ ">>> Analyse Mod:" ++ show thisMod
    logLastCallAnalysis $ ">>> Ordered Procs:" ++ show orderedProcs
    logLastCallAnalysis $ ">>> Analyse SCCs: \n" ++
        unlines (List.map ((++) "    " . show . sccElts) orderedProcs)
    tcmcOpt <- gets (optimisationEnabled TailCallModCons . options)
    when tcmcOpt $ mapM_ (updateEachProcM lastCallAnalyseProc) orderedProcs
    -- We need to fixup calls regardless whether tcmc is enabled or not,
    -- as there could be modified calls to e.g.: standard library functions
    -- Also, we try where possible to write outByReference outputs from other
    -- calls directly into a destination structure, rather than first `load`
    -- then `mutate`.
    mapM_ (updateEachProcM fixupProc) orderedProcs
    reexitModule

-- | Apply a mapping function to each proc in an SCC
updateEachProcM :: (ProcDef -> Compiler ProcDef) -> SCC ProcSpec -> Compiler ()
updateEachProcM f (AcyclicSCC pspec) = updateProcDefM f pspec
updateEachProcM f (CyclicSCC pspecs) = mapM_ (updateProcDefM f) pspecs

-- | Analyse whether a proc is suitable for last-call -> tail-call transformation.
-- If so, we:
--   (1) modify the function's signature, switching some outputs to FlowOutByReference
--   (2) mark the last call with the LPVM `tail` attribute
--   (3) mark the mutate() instructions after the last call with `takeReference` flows
lastCallAnalyseProc :: ProcDef -> Compiler ProcDef
lastCallAnalyseProc def = do
    let impln = procImpln def
    let spec = procImplnProcSpec impln
    let proto = procImplnProto impln
    let body = procImplnBody impln
    logLastCallAnalysis $ ">>> Last Call Analysis: " ++ show spec
    case procVariant def of
        ClosureProc {} -> do
            logLastCallAnalysis "skipping closure proc, shouldn't have direct tail-recursion anyway"
            return def
        _ -> do
            (maybeBody', finalState) <- runStateT (runMaybeT (mapProcLeavesM transformLeaf body))
                LeafTransformState { procSpec = spec, originalProto = proto, outByReferenceArguments = Set.empty }
            case maybeBody' of
                Just body' -> do
                    proto' <- modifyProto proto (outByReferenceArguments finalState)
                    logLastCallAnalysis $ "new proto: " ++ show proto'
                    return def {procImpln = impln{procImplnProto = proto', procImplnBody = body'}}
                _ -> return def

data LeafTransformState = LeafTransformState {
    procSpec :: ProcSpec,
    originalProto :: PrimProto,
    outByReferenceArguments :: Set PrimVarName
}

type LeafTransformer = MaybeT (StateT LeafTransformState Compiler)

-- | Run our analysis on a single leaf of the function body,
-- collecting state inside the LeafTransformer monad.
--
-- XXX: we should relax the assumption that last calls must be in the
-- leaves of a proc body, as there are real-world examples which defy this
-- assumption, e.g.: see test-cases/final-dump/tcmc_partition.wybe.
transformLeaf :: [Placed Prim] -> LeafTransformer [Placed Prim]
transformLeaf lastBlock = do
    spec <- gets procSpec
    case partitionLastCall lastBlock of
        -- XXX: we currently only consider directly-recursive calls,
        --      it would be nice to handle mutual recursion too.
        (Just (beforeCall, lastCall), afterLastCall@(_:_)) | primIsCallToProcSpec lastCall spec -> do
            logLeaf $ "identified a directly-recursive last-call: " ++ show lastCall
            logLeaf $ "before: " ++ show beforeCall ++ "\nafter: " ++ show afterLastCall
            -- First we identify whether we can move this last call below some of the prims
            -- i.e.: the prims don't depend on any values produced by the last call
            let (movedAboveCall, remainingBelowCall) = tryMovePrimBelowPrims lastCall afterLastCall
            logLeaf $ "prims still remaining below last call: " ++ show remainingBelowCall
            -- Next, we look at the remaining prims which couldn't be simply moved before the last call,
            -- to see if they are just "filling in the fields" of struct(s) with
            -- outputs from the last call.
            (mutateChains, remainingBelowCall') <- lift2 $ analyzePrimsAfterCall lastCall isOutputFlow remainingBelowCall
            case remainingBelowCall' of
                [] -> do
                    -- The output parameters which we want to convert to be
                    -- `FlowOutByReference` are the union of parameters we want to
                    -- convert for each leaf in the proc body.
                    modify (\state@LeafTransformState{outByReferenceArguments=outByRefArgs} ->
                        state { outByReferenceArguments = Set.union outByRefArgs $ Set.fromList [outputName (last mutateChain) | mutateChain <- mutateChains]}
                        )

                    -- We annotate the final call + remaining mutates with appropriate
                    -- `FlowOutByReference` and `FlowTakeReference` flows.
                    body' <- lift2 $ buildTailCallLeaf (beforeCall ++ movedAboveCall) lastCall mutateChains

                    logLeaf "remaining prims meet requirements tail call transformation"
                    logLeaf $ "identified mutate chains: " ++ show mutateChains
                    logLeaf $ "modified body: " ++ show body'
                    return body'
                _ -> do
                    logLeaf $ "there were leftover prims which didn't satisfy constraints: " ++ show remainingBelowCall'
                    return lastBlock
        (Just (_, call), []) | primIsCallToProcSpec call spec -> do
            logLeaf "directly-recursive last call is already in tail position"
            return lastBlock
        (Just (_, call), _) -> do
            logLeaf $ "leaf didn't qualify for last-call transformation\n    last call: " ++ show call ++ "\n    pspec: " ++ show spec
            return lastBlock
        _ -> do
            logLeaf $ "leaf didn't qualify for last-call transformation - didn't find a tail call"
            return lastBlock

-- Returns true if this prim is calling proc spec
primIsCallToProcSpec :: Placed Prim -> ProcSpec -> Bool
primIsCallToProcSpec p spec = case content p of
    (PrimCall _ spec' _ _) | procSpecMod spec == procSpecMod spec' &&
                             procSpecName spec == procSpecName spec' &&
                             procSpecID spec == procSpecID spec' -> True
    _ -> False

-- | Returns true if `prim` uses any of the outputs generated by `otherPrims`
-- If this is the case, then it is not possible to move `prim` before the last call.
primUsesOutputsOfOtherPrims :: Prim -> [Prim] -> Bool
primUsesOutputsOfOtherPrims prim otherPrims =
    let (args, globals) = primArgs prim
        vars = varsInPrimArgs isInputFlow args
        otherPrimOutputs = varsInPrims isOutputFlow otherPrims
    in
    -- if the prim refers to any global variables, then skip reordering (conservative approximation for now)
    -- otherwise, check it doesn't refer to any outputs from `otherPrims`
    not (UnivSet.isEmpty (globalFlowsIn globals) && UnivSet.isEmpty (globalFlowsOut globals)) || any (`elem` otherPrimOutputs) vars

-- | Converts a subset of proc outputs to be
--   `FlowOutByReference` instead of `FlowOut`
modifyProto :: PrimProto -> Set PrimVarName -> Compiler PrimProto
modifyProto proto outputNames = do
    let params = primProtoParams proto
    let makeParamsOutByReference = (\param@PrimParam{primParamName = name, primParamFlow=flow } ->
            if name `notElem` outputNames then
                param
            else case flow of
                FlowOutByReference -> shouldnt "multiple mutate chains writing to same output"
                FlowTakeReference -> shouldnt "takeReference arg should only appear as the last argument to a mutate() instruction"
                FlowIn -> shouldnt $ "attempting to convert parameter " ++ show name ++ " from FlowIn -> FlowOutByReference.\nproto: " ++ show proto
                FlowOut -> param { primParamFlow = FlowOutByReference }
            )
    return proto { primProtoParams = map makeParamsOutByReference params }

-- | Instead of a series of mutates *after* the last call, we instead
-- perform some extra setup *before* the last call, allowing the last call
-- of this block to be in tail-position.
buildTailCallLeaf :: [Placed Prim] -> Placed Prim -> [MutateChain (Placed Prim)] -> Compiler [Placed Prim]
buildTailCallLeaf beforeCall call mutateChains = do
    let modifiedMutates = concatMap annotateFinalMutates mutateChains
    let call' = contentApply (transformIntoTailCall mutateChains) call
    return $ beforeCall ++ [call'] ++ modifiedMutates

-- | Annotates mutates which remain after the tail call with FlowTakeReference
-- This indicates that the mutation will not actually occur after the call,
-- instead, we take a reference to the memory location the mutate would have
-- written to, and pass that reference into the tail call as an `outByReference`
-- parameter.
annotateFinalMutates :: HasPrim a => MutateChain a -> [a]
annotateFinalMutates = map $
    mapPrim (\case {
            PrimForeign "lpvm" "mutate" flags [input, output, offset, destructive, size, startOffset, val] ->
                PrimForeign "lpvm" "mutate" flags [input, output, offset, destructive, size, startOffset, setArgFlow FlowTakeReference val ];
            _ -> shouldnt "must be mutate instr"
    }) . prim

-- | Given a set of mutate chains (which are linear sequences of mutations
-- occuring after the call), decorate this call with appropriate
-- `outByReference` args.
transformIntoTailCall :: [MutateChain a] -> Prim -> Prim
transformIntoTailCall mutateChains (PrimCall siteId spec args globalFlows) =
    let mutates = concat mutateChains in
    PrimCall siteId spec (map (\arg ->
        case arg of
            var@ArgVar { argVarName = name } | name `elem` List.map valueName mutates
                -> var { argVarFlow = FlowOutByReference }
            _ -> arg
        ) args) globalFlows
transformIntoTailCall mutateChains _ = shouldnt "not a call"

data MutateInstr a = MutateInstr {
    prim      :: a,
    inputName :: PrimVarName,
    outputName :: PrimVarName,
    valueName :: PrimVarName,
    offset :: Integer
} deriving(Show)

type MutateChain a = [MutateInstr a]
type LastCall = Placed Prim

class Show a => HasPrim a where
    getPrim :: a -> Prim
    mapPrim :: (Prim->Prim) -> a -> a

instance HasPrim (Placed Prim) where
    getPrim = content
    mapPrim = contentApply

instance HasPrim (Bool, Placed Prim) where
    getPrim (_, p) = content p
    mapPrim f (x, p) = (x, contentApply f p)

-- XXX: may need to update 'last use' flags here?
tryMovePrimBelowPrims :: HasPrim a => a -> [a] -> ([a], [a])
tryMovePrimBelowPrims prim otherPrims =
    let (above, below) = tryMovePrimBelowPrims' prim otherPrims ([], []) in (reverse above, reverse below)

tryMovePrimBelowPrims' :: HasPrim a => a -> [a] -> ([a], [a]) -> ([a], [a])
tryMovePrimBelowPrims' _ [] state = state
tryMovePrimBelowPrims' prim (nextPrim:nextPrims) (above, below) =
    let nextPrim' = getPrim nextPrim
        otherPrims = List.map getPrim (prim : below ++ nextPrims) in
    if primUsesOutputsOfOtherPrims nextPrim' otherPrims
    then tryMovePrimBelowPrims' prim nextPrims (above, nextPrim : below)
    else tryMovePrimBelowPrims' prim nextPrims (nextPrim : above, below)

analyzePrimsAfterCall :: HasPrim a => a -> (PrimFlow -> Bool) -> [a] -> Compiler ([MutateChain a], [a])
analyzePrimsAfterCall call allowedOutputs prims = foldrM (analyzePrimAfterCall call allowedOutputs) ([],[]) (reverse prims)

-- | The only prims allowed after a "would-be tail call" are `foreign lpvm mutate`
-- instructions, with specific conditions (i.e.: the fields they are writing
-- into don't alias)
analyzePrimAfterCall :: HasPrim a => a -> (PrimFlow -> Bool) -> a -> ([MutateChain a], [a]) -> Compiler ([MutateChain a], [a])
analyzePrimAfterCall lastCall allowedOutputs prim (chains, unsuccessfulPrims) = do
    case getPrim prim of
        PrimForeign "lpvm" "mutate" _ mutateInstr@[
            ArgVar { argVarName = input, argVarFlow = FlowIn },
            ArgVar { argVarName = output, argVarFlow = FlowOut },
            offsetArg, ArgInt 1 _, _, _,
            ArgVar { argVarName = valueName, argVarFlow = FlowIn, argVarFinal = final }] ->
            -- Tricky corner-case:
            -- When we are analyzing prims for the purposes of *deciding*
            -- whether or not we can make this call a tail call,
            -- we allow any FlowOut or FlowOutByReference output, since
            -- we will transform those outputs to be FlowOutByReference later on.
            -- However when we are analyzing prims for the purposes of writing
            -- directly into structures from an existing tail call,
            -- then we consider only outputs which are already
            -- FlowOutByReference, since we won't change the call signature anymore.
            case (final, valueName `elem` varsInPrim allowedOutputs (getPrim lastCall)) of
                (False, _) -> do
                    logLastCallAnalysis $ show valueName ++ " is used in more than one place"
                    return ([], prim:unsuccessfulPrims)
                (_, False) -> do
                    logLastCallAnalysis $ "failed to add " ++ show prim ++ " to mutate chain " ++ show chains
                                ++ " - " ++ show valueName ++ " doesn't originate from a FlowOutByReference output of the call"
                    return ([], prim:unsuccessfulPrims)
                _ -> do
                    logLastCallAnalysis $ "trying to add " ++ show prim ++ " to mutate chain"
                    let result = tryAddToMutateChain lastCall (List.map outputName (concat chains))
                            MutateInstr
                                {prim = prim, inputName = input, outputName = output,
                                offset = trustArgInt offsetArg, valueName = valueName} chains
                    case result of
                        Left s -> do
                            logLastCallAnalysis $ "failed to add " ++ show prim ++ " to mutate chain: " ++ s
                            return ([], prim:unsuccessfulPrims)
                        Right chains' -> do
                            logLastCallAnalysis $ "added to chain. chains' = " ++ show chains'
                            return (chains', unsuccessfulPrims)
        _ -> do
            logLastCallAnalysis $ show (getPrim prim) ++ " - not a mutate instr satisfying constraints"
            return ([], prim:unsuccessfulPrims)

-- | We build up these "mutate-chains" incrementally,
-- aborting early if the conditions aren't satisfied.
-- This analysis makes sure that we have (zero or more) linear sequences
-- where each mutate in a sequence writes to a non-overlapping field.
tryAddToMutateChain :: HasPrim a => a -> [PrimVarName] -> MutateInstr a -> [MutateChain a] -> Either String [MutateChain a]
-- We're adding to the "last" mutate chain
tryAddToMutateChain lastCall existingIntermediateOutputs mut1 (chain@(mut:muts):chains) | outputName mut == inputName mut1 =
    if offset mut `notElem` List.map offset chain
    then Right $ (mut1:chain):chains
    -- We check that writes in a single mutate-chain don't alias fields.
    -- Aliasing could be bad, since we cannot guarantee that the
    -- callee will write it's outByReference arguments in any particular order.
    --
    -- XXX: take into account size as well as offset when determining aliasing?
    else Left "offsets alias"
-- Trying to add to a previous mutate chain instead
tryAddToMutateChain lastCall existingIntermediateOutputs mut1 (chain:chains) = do
    chains' <- tryAddToMutateChain lastCall existingIntermediateOutputs mut1 chains
    return $ chain:chains'
-- Trying to start a *new* mutate chain
tryAddToMutateChain lastCall existingIntermediateOutputs mut' [] = let inputArg = inputName mut' in
    if inputArg `elem` varsInPrim isOutputFlow (getPrim lastCall) || inputArg `elem` existingIntermediateOutputs
    then
        Left "input arg is either generated by the last call, or by reusing an intermediate output from an existing mutate-chain."
    else
        Right [[mut']]

----------------------------------------------------------------------------
-- Write outByReference outputs directly into structures                  --
----------------------------------------------------------------------------

data ProcBodyAnnot = ProcBodyAnnot {
      bodyPrims' ::[(Bool, Placed Prim)],
      bodyFork' ::PrimForkAnnot}
              deriving (Eq, Show)

data PrimForkAnnot =
    NoForkAnnot |
    PrimForkAnnot {
      forkVar' :: PrimVarName,       -- ^The variable that selects branch to take
      forkVarType' :: TypeSpec,      -- ^The Wybe type of the forkVar
      forkVarLast' :: Bool,          -- ^Is this the last occurrence of forkVar
      forkBodies' :: [ProcBodyAnnot] -- ^one branch for each value of forkVar
    }
    deriving (Eq, Show)

allUnvisited :: ProcBody -> ProcBodyAnnot
allUnvisited body@ProcBody { bodyPrims=prims, bodyFork=fork} = ProcBodyAnnot { bodyPrims' = map (\p -> (False, p)) prims, bodyFork' =allUnvisitedFork fork}
allUnvisitedFork :: PrimFork -> PrimForkAnnot
allUnvisitedFork NoFork = NoForkAnnot
allUnvisitedFork PrimFork{forkVar=var, forkVarType=varTy, forkVarLast=varLast, forkBodies=bodies} = PrimForkAnnot{forkVar'=var, forkVarType'=varTy, forkVarLast'=varLast, forkBodies'=map allUnvisited bodies}

stripVisited :: ProcBodyAnnot -> ProcBody
stripVisited body@ProcBodyAnnot { bodyPrims'=prims, bodyFork'=fork} = ProcBody { bodyPrims = map snd prims, bodyFork = stripVisitedFork fork}
stripVisitedFork :: PrimForkAnnot -> PrimFork
stripVisitedFork NoForkAnnot = NoFork
stripVisitedFork PrimForkAnnot{forkVar'=var, forkVarType'=varTy, forkVarLast'=varLast, forkBodies'=bodies} = PrimFork {forkVar=var, forkVarType=varTy, forkVarLast=varLast, forkBodies=map stripVisited bodies}

writeOutputsDirectlyIntoStructures :: ProcBodyAnnot -> Compiler ProcBodyAnnot
writeOutputsDirectlyIntoStructures procBody@ProcBodyAnnot{bodyPrims'=[], bodyFork'=NoForkAnnot} = return procBody
writeOutputsDirectlyIntoStructures procBody@ProcBodyAnnot{bodyPrims'=[], bodyFork'=fork@PrimForkAnnot{forkBodies'=bodies}} = do
    bodies' <- mapM writeOutputsDirectlyIntoStructures bodies
    return procBody{bodyFork'=fork{forkBodies'=bodies'}}
writeOutputsDirectlyIntoStructures procBody@ProcBodyAnnot{bodyPrims'=call0@(False, call):prims} = do
    let argFlows = Set.fromList $ map argFlowDirection (fst . primArgs . content $ call)
    newBody <- if FlowOutByReference `elem` argFlows then do
            logLastCallAnalysis $ "call " ++ show call ++ " has outByReference outputs"
            logLastCallAnalysis $ "trying to move call " ++ show call ++ " down right before outputs are needed"
            let (above, below) = tryMovePrimBelowPrims call0 prims
            logLastCallAnalysis $ "moved below: " ++ show above
            logLastCallAnalysis $ "remaining below: " ++ show below
            -- For each FlowOutByReference output, we want to know if it
            -- appears as the last argument to exactly 1 mutate().
            -- In this case, we believe it is safe to turn that mutate into a
            -- `FlowTakeReference`-style mutate.
            (mutateChains, below') <- analyzePrimsAfterCall call0 (==FlowOutByReference) below
            if null mutateChains then do
                logLastCallAnalysis "collected no mutate chains - perhaps this result isn't written into a structure?"
                return procBody{bodyPrims'=(True, call):prims}
            else do
                logLastCallAnalysis $ "collected mutate chains: " ++ show mutateChains
                let below'' = annotateFinalMutates (concat mutateChains) ++ below'
                let body' = procBody{bodyPrims'=above ++ (True, call):below''}
                logLastCallAnalysis $ "new body: " ++ show (stripVisited body')
                return body'
        else return procBody{bodyPrims'=(True, call):prims}
    writeOutputsDirectlyIntoStructures newBody
writeOutputsDirectlyIntoStructures body@ProcBodyAnnot{bodyPrims'=(visited, prim):prims} = do
    body' <- writeOutputsDirectlyIntoStructures body{bodyPrims'=prims}
    return $ body'{bodyPrims'=(True, prim):bodyPrims' body'}

----------------------------------------------------------------------------
-- Coerce FlowOut into FlowOutByReference                                 --
----------------------------------------------------------------------------

-- | Check the proc protos of all callees, and coerce FlowOut into
-- FlowOutByReference where needed.
fixupProc :: ProcDef -> Compiler ProcDef
fixupProc def@ProcDef { procImpln = impln@ProcDefPrim { procImplnBody = body}} = do
    logLastCallAnalysis $ ">>> Fix up calls in proc: " ++ show (procName def)
    body' <- mapProcPrimsM (updatePlacedM fixupPrim) body
    logLastCallAnalysis $ ">>> Write outputs directly into structures: " ++ show (procName def)
    body'' <- writeOutputsDirectlyIntoStructures (allUnvisited body')
    let body''' = stripVisited body''
    return $ def { procImpln = impln { procImplnBody = body''' } }
fixupProc _ = shouldnt "uncompiled"

fixupPrim :: Prim -> Compiler Prim
fixupPrim p@(PrimCall siteId pspec args gFlows) = do
    logLastCallAnalysis $ "checking call " ++ show p
    proto <- getProcPrimProto pspec
    let args' = coerceArgs args (primProtoParams proto)
    when (args /= args') $ logLastCallAnalysis $ "coerced args: " ++ show args ++ " " ++ show args'
    return $ PrimCall siteId pspec args' gFlows
fixupPrim p = return p

-- | Coerce FlowOut arguments into FlowOutByReference where needed
coerceArgs :: [PrimArg] -> [PrimParam] -> [PrimArg]
coerceArgs [] []    = []
coerceArgs [] (_:_) = shouldnt "more parameters than arguments"
coerceArgs (_:_) [] = shouldnt "more arguments than parameters"
coerceArgs (a@ArgVar{argVarFlow = FlowOut}:as) (p@PrimParam{primParamFlow=FlowOutByReference }:ps) =
    let rest = coerceArgs as ps in
    a { argVarFlow = FlowOutByReference }:rest
coerceArgs (a:as) (p:ps) = a:coerceArgs as ps

----------------------------------------------------------------------------
-- Helpers                                                                --
----------------------------------------------------------------------------

partitionLastCall :: [Placed Prim] -> (Maybe ([Placed Prim], Placed Prim), [Placed Prim])
partitionLastCall prims = let (lastCall, after) = _partitionLastCall $ reverse prims
    in (lastCall, reverse after)

_partitionLastCall :: [Placed Prim] -> (Maybe ([Placed Prim], Placed Prim), [Placed Prim])
_partitionLastCall [] = (Nothing, [])
_partitionLastCall (x:xs) =
    case content x of
        PrimCall {} -> (Just (reverse xs, x), [])
        _ -> let (lastCall, afterLastCall) = _partitionLastCall xs
            in (lastCall, x:afterLastCall)

-- | Applies a transformation to the leaves of a proc body
mapProcLeavesM :: (Monad t) => ([Placed Prim] -> t [Placed Prim]) -> ProcBody -> t ProcBody
mapProcLeavesM f leafBlock@ProcBody { bodyPrims = prims, bodyFork = NoFork } = do
        prims <- f prims
        return leafBlock { bodyPrims = prims }
mapProcLeavesM f current@ProcBody { bodyFork = fork@PrimFork{forkBodies = bodies} } = do
        bodies' <- mapM (mapProcLeavesM f) bodies
        return current { bodyFork = fork { forkBodies = bodies' } }

-- | Applies a transformation to each prim in a proc
mapProcPrimsM :: (Monad t) => (Placed Prim -> t (Placed Prim)) -> ProcBody -> t ProcBody
mapProcPrimsM fn body@ProcBody { bodyPrims = prims, bodyFork = NoFork } = do
        prims' <- mapM fn prims
        return body { bodyPrims = prims' }
mapProcPrimsM fn body@ProcBody { bodyPrims = prims, bodyFork = fork@PrimFork{forkBodies = bodies } } = do
        prims' <- mapM fn prims
        bodies <- mapM (mapProcPrimsM fn) bodies
        return body { bodyPrims = prims', bodyFork = fork { forkBodies = bodies } }

----------------------------------------------------------------------------
-- Logging                                                                --
----------------------------------------------------------------------------

-- | Logging from the Compiler monad to LastCallAnalysis.
logLastCallAnalysis :: String -> Compiler ()
logLastCallAnalysis = logMsg LastCallAnalysis

-- | Logging from the Compiler monad to LastCallAnalysis.
logLeaf :: String -> LeafTransformer ()
logLeaf s = lift2 $ logMsg LastCallAnalysis s
