--  File     : BodyBuilder.hs
--  Author   : Peter Schachte
--  Purpose  : A monad to build up a procedure Body, with copy propagation
--  Copyright: (c) 2015 Peter Schachte.  All rights reserved.
--  License  : Licensed under terms of the MIT license.  See the file
--           : LICENSE in the root directory of this project.


module BodyBuilder (
  BodyBuilder, buildBody, freshVarName, instr, buildFork, completeFork,
  beginBranch, endBranch, definiteVariableValue
  ) where

import AST
import Debug.Trace
import Snippets ( boolType, intType, primMove )
import Util
import Options (LogSelection(BodyBuilder))
import Data.Map as Map
import Data.List as List
import Data.Set as Set
import UnivSet as USet
import Data.Maybe
import Data.Tuple.HT (mapFst)
import Data.Bits
import Control.Monad
import Control.Monad.Extra (whenJust, whenM)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.State


----------------------------------------------------------------
--                       The BodyBuilder Monad
--
-- This monad is used to build up a ProcBody one instruction at a time.
--
-- buildBody runs the monad, producing a ProcBody.
-- instr adds a single instruction to then end of the procBody being built.
-- Forks are produced by the following functions:
--    buildFork     initiates a fork on a specified variable
--    beginBranch   starts a new branch of the current fork
--    endBranch     ends the current branch
--    completeFork  completes the current fork
--
-- A ProcBody is considered to have a unique continuation if it either
-- does not end in a branch, or if all but at most one of the branches
-- it ends with ends with a definite failure (a PrimTest (ArgInt 0 _)).
--
-- No instructions can be added between buildFork and beginBranch, or
-- between endBranch and beginBranch, or if the current state does not have
-- a unique continuation. A new fork can be built within a branch, but must
-- be completed before the branch is ended.
--
-- The ProcBody type does not support having anything follow a fork. Once a
-- ProcBody forks, the branches do not join again. Instead, each branch of
-- a fork should end with a call to another proc, which does whatever
-- should come after the fork. To handle this, once a fork is completed,
-- the BodyBuilder starts a new Unforked instruction sequence, and records
-- the completed fork as the prev of the Unforked sequence. This
-- also permits a fork to follow the Unforked sequence which follows a
-- fork. When producing the final ProcBody, if the current Unforked
-- sequence is short (or empty) and there is a prev fork, we simply
-- add the sequence to the end of each of branch of the fork and remove the
-- Unforked sequence. If it is not short and there is a prev, we
-- create a fresh proc whose input arguments are all the live variables,
-- whose outputs are the current proc's outputs, and whose body is built
-- from Unforked sequence, add a call to this fresh proc to each branch of
-- the previous Forked sequence, and remove the Unforked.
--
-- We handle a Forked sequence by generating a ProcBody for each branch,
-- collecting these as the branches of a ProcBody, and taking the
-- instructions from the preceding Unforked as the instruction sequence of
-- the ProcBody.
--
-- Note that for convenience/efficiency, we collect the instructions in a
-- sequence and the branches in a fork in reverse order, so these are
-- reversed when converting to a ProcBody.
--
-- Some transformation is performed by the BodyBuilder monad; in
-- particular, we keep track of variable=variable assignments, and replace
-- references to the destination (left) variable with the source (right)
-- variable.  This usually leaves the assignment dead, to be removed in
-- a later pass.  We also keep track of previous instructions, and later
-- calls to the same instructions with the same inputs are replaced by
-- assignments to the outputs with the old outputs.  We also handle some
-- arithmetic equivalences, entailments, and tautologies (eg, on a branch
-- where we know x==y, a call to x<=y will always return true; for
-- unsigned x, x<0 is always false, and x>0 is replaced with x!=0).
-- We also maintain a counter for temporary variable names.
--
-- The BodyState has two constructors:  Unforked is used before the first
-- fork, and after each new branch is created. Instructions can just be
-- added to this. Forked is used after a new fork is begun and before its
-- first branch is created, between ending a branch and starting a new one,
-- and after the fork is completed. New instructions can be added and new
-- forks built only when in the Unforked state. In the Forked state, we can
-- only create a new branch.
--
-- These constructors are used in a zipper-like structure, where the top of the
-- structure is the part we're building, and below that is the parent, ie,
-- the fork structure of which it's a part. This is implemented as follows:
--
--     buildFork is called when the state is Unforked.  It creates a new
--     Forked state, with the old state as its origin and an empty list
--     of bodies.  The new parent is the same as the old one.
--
--     beginBranch is called when the state is Forked.  It creates a new
--     Unforked state with the old state as parent.
--
--     endBranch is called with either a Forked or Unforked state.  It
--     adds the current state to the parent state's list of bodies and
--     makes that the new state.
--
--     completeFork is called when the state is Forked.  It doesn't
--     change the state.
----------------------------------------------------------------

type BodyBuilder = StateT BodyState Compiler

-- Holds the content of a ProcBody while we're building it.
data BodyState = BodyState {
      currBuild     :: [Placed Prim],   -- ^The body we're building, reversed
      currSubst     :: Substitution,    -- ^variable substitutions to propagate
      blockDefs     :: Set PrimVarName, -- ^All variables defined in this block
      forkConsts    :: Set PrimVarName, -- ^Consts in some branches of prev fork
      outSubst      :: VarSubstitution, -- ^Substitutions for var assignments
      subExprs      :: ComputedCalls,   -- ^Previously computed calls to reuse
      failed        :: Bool,            -- ^True if this body always fails
      tmpCount      :: Int,             -- ^The next temp variable number to use
      buildState    :: BuildState,      -- ^The fork at the bottom of this node
      parent        :: Maybe BodyState, -- ^What comes before/above this
      globalsLoaded :: Map GlobalInfo PrimArg
                                        -- ^The set of globals that we currently 
                                        -- know the value of
      } deriving (Eq,Show)


data BuildState
    = Unforked                         -- ^Still building; ready for more instrs
    | Forked {
        forkingVar   :: PrimVarName,   -- ^Variable that selects branch to take
        forkingVarTy :: TypeSpec,      -- ^Type of forkingVar
        knownVal     :: Maybe Integer, -- ^Definite value of forkingVar if known
        fused        :: Bool,          -- ^forkingVar is a constant in every
                                       -- branch in the parent fork, so this
                                       -- fork will be fused with parent fork
        bodies       :: [BodyState],   -- ^Rev'd BodyStates of branches so far
        complete     :: Bool           -- ^Whether the fork has been completed
        }                              -- ^Building a new fork
    deriving (Eq,Show)



-- | A fresh BodyState with specified temp counter and output var substitution
initState :: Int -> VarSubstitution -> BodyState
initState tmp oSubst =
    BodyState [] Map.empty Set.empty Set.empty oSubst Map.empty False tmp
              Unforked Nothing Map.empty


-- | Set up a BodyState as a new child of the specified BodyState
childState :: BodyState -> BuildState -> BodyState
childState st@BodyState{currSubst=iSubst,outSubst=oSubst,subExprs=subs,
                        tmpCount=tmp, forkConsts=consts, globalsLoaded=loaded} bld =
    BodyState [] iSubst Set.empty consts oSubst subs False tmp bld (Just st) loaded


-- | A mapping from variables to definite values, in service to constant
-- propagation.
type Substitution = Map PrimVarName PrimArg


-- | A mapping from variables to their renamings.  This is in service to
-- variable elimination.
type VarSubstitution = Map PrimVarName PrimVarName


-- To handle common subexpression elimination, we keep a map from previous
-- calls with their outputs removed.  This type encapsulates
-- that.  In the Prim keys, all PrimArgs are inputs.
type ComputedCalls = Map Prim [PrimArg]


-- |Allocate the next temp variable name and ensure it's not allocated again
freshVarName :: BodyBuilder PrimVarName
freshVarName = do
    tmp <- gets tmpCount
    modify (\st -> st {tmpCount = tmp + 1})
    return $ PrimVarName (mkTempName tmp) 0



----------------------------------------------------------------
--                      BodyBuilder Primitive Operations
----------------------------------------------------------------

-- |Run a BodyBuilder monad and extract the final proc body, along with the
-- final temp variable count and the set of variables used in the body.
buildBody :: Int -> VarSubstitution 
          -> BodyBuilder a -> Compiler (a, Int, Set PrimVarName, ProcBody)
buildBody tmp oSubst builder = do
    logMsg BodyBuilder "<<<< Beginning to build a proc body"
    (a, st) <- runStateT builder $ initState tmp oSubst
    logMsg BodyBuilder ">>>> Finished building a proc body"
    logMsg BodyBuilder "     Final state:"
    logMsg BodyBuilder $ fst $ showState 8 st
    st' <- fuseBodies st
    (tmp', used, body) <- currBody (ProcBody [] NoFork) st'
    return (a, tmp', used, body)


-- |Start a new fork on var of type ty
buildFork :: PrimVarName -> TypeSpec -> BodyBuilder ()
buildFork var ty = do
    st <- get
    var' <- expandVar var boolType
    logBuild $ "<<<< beginning to build a new fork on " ++ show var
               ++ " (-> " ++ show var' ++ ")"
    case buildState st of
      Forked{complete=True} ->
        shouldnt "Building a fork in Forked state"
      Forked{complete=False} ->
        shouldnt "Building a fork in Forking state"
      Unforked -> do
        arg' <- expandVar var ty
        logBuild $ "     (expands to " ++ show arg' ++ ")"
        case arg' of
          ArgInt n _ -> -- fork variable value known at compile-time
            put $ childState st $ Forked var ty (Just n) False [] False
          ArgVar{argVarName=var',argVarType=varType} -> do
            -- statically unknown result
            consts <- gets forkConsts
            logBuild $ "Consts from parent fork = " ++ show consts
            let fused = Set.member var' consts
            logBuild $ "This fork "
                       ++ (if fused then "WILL " else "will NOT ")
                       ++ "be fused with parent"
            put $ st {buildState=Forked var' ty Nothing fused [] False}
          _ -> shouldnt "switch on non-integer variable"
        logState


-- |Complete a fork previously initiated by buildFork.
completeFork :: BodyBuilder ()
completeFork = do
    st <- get
    case buildState st of
      Forked{complete=True} ->
        shouldnt "Completing an already-completed fork"
      Unforked ->
        shouldnt "Completing an un-built fork"
      Forked var ty val fused bods False -> do
        logBuild $ ">>>> ending fork on " ++ show var
        -- let branchMap = List.foldr1 (Map.intersectionWith Set.union)
        --                 (Map.map Set.singleton
        --                  . Map.filter argIsConst . currSubst <$> bods)
        let branchMaps = Map.filter argIsConst . currSubst <$> bods
        -- Variables set to the same constant in every branch
        let extraSubsts = List.foldr1 intersectMapIdentity branchMaps
        logBuild $ "     extraSubsts = " ++ show extraSubsts
        -- Variables with a constant value in each branch.  These can be
        -- used later to fuse branches of subsequent forks on those variables
        -- with this fork.
        let consts = List.foldr1 Set.union
                     $ List.map Map.keysSet branchMaps
        logBuild $ "     definite variables in all branches: " ++ show consts
        -- Prepare for any instructions coming after the fork
        let parent = st {buildState = Forked var ty val fused bods True,
                         tmpCount = maximum $ tmpCount <$> bods }
        let child = childState parent Unforked
        put $ child { forkConsts = consts,
                      currSubst = Map.union extraSubsts $ currSubst child}
        logState


-- |Start a new branch for the next integer value of the switch variable.
beginBranch :: BodyBuilder ()
beginBranch = do
    st <- get
    case buildState st of
      Forked{complete=True} ->
        shouldnt "Beginning a branch in an already-completed fork"
      Unforked ->
        shouldnt "Beginning a branch in an un-built fork"
      Forked var ty val fused bods False -> do
        let branchNum = length bods
        logBuild $ "<<<< <<<< Beginning to build "
                   ++ (if fused then "fused " else "") ++ "branch "
                   ++ show branchNum ++ " on " ++ show var
        when fused $ do
          par <- gets $ trustFromJust "forkConst with no parent branch" . parent
          case buildState par of
            Forked{bodies=bods} -> do
              let matchingSubsts =
                    List.map currSubst
                    $ List.filter (matchingSubst var branchNum) bods
              let extraSubsts =
                    if List.null matchingSubsts
                    then Map.empty
                    else List.foldr1 intersectMapIdentity matchingSubsts
              logBuild $ "          Adding substs " ++ show extraSubsts
              -- XXX shouldn't need to do this sanity check
        --       lostSubsts <- (Map.\\ extraSubsts) <$> gets currSubst
        --       unless (Map.null lostSubsts )
        --         $ shouldnt $ "Fusion loses substs " ++ simpleShowMap lostSubsts
              modify $ \st -> st { currSubst =
                                   Map.union extraSubsts (currSubst st) }
            Unforked -> shouldnt "forkConst predicted parent branch"
        put $ childState st Unforked
        -- XXX also add consequences of this, eg if var is result of X==Y
        --     comparison and var == 1, then record that X==Y.
        when (isNothing val && not fused)
          $ addSubst var $ ArgInt (fromIntegral branchNum) intType
        logState


-- |End the current branch.
endBranch :: BodyBuilder ()
endBranch = do
    st <- get
    (par,st,var,ty,val,fused,bodies) <- gets popParent
    logBuild $ ">>>> >>>> Ending branch "
               ++ show (length bodies) ++ " on " ++ show var
    put $ par { buildState=Forked var ty val fused (st:bodies) False }
    logState


-- |Return the closest Forking ancestor of a state, and fix its immediate
--  child to no longer list it as parent
popParent :: BodyState -> (BodyState,BodyState,PrimVarName,TypeSpec,
                           Maybe Integer,Bool,[BodyState])
popParent st@BodyState{parent=Nothing} =
    shouldnt "endBranch with no open branch to end"
popParent st@BodyState{parent=(Just
             par@BodyState{buildState=(Forked var ty val fused
                                       branches False)})} =
    (par, st {parent = Nothing}, var, ty, val, fused, branches)
popParent st@BodyState{parent=Just par} =
    let (ancestor, fixedPar, var, ty, val, fused, branches) = popParent par
    in  (ancestor,st {parent=Just fixedPar}, var, ty, val, fused, branches)


-- | Test if the specified variable is bound to the specified constant in the
-- specified BodyState.
matchingSubst :: PrimVarName -> Int -> BodyState -> Bool
matchingSubst var branchNum bod =
  maybe False ((== branchNum) . fromIntegral) $ varIntValue var bod


-- |Return Just the known value of the specified variable, or Nothing
varIntValue :: PrimVarName -> BodyState -> Maybe Integer
varIntValue var bod = Map.lookup var (currSubst bod) >>= argIntegerValue


definiteVariableValue :: PrimVarName -> BodyBuilder (Maybe PrimArg)
definiteVariableValue var = do
    arg <- expandVar var AnyType
    case arg of
        ArgVar{} -> return Nothing -- variable (unknown) result
        _ -> return $ Just arg


-- |Add an instruction to the current body, after applying the current
--  substitution. If it's a move instruction, add it to the current
--  substitution.
instr :: Prim -> OptPos -> BodyBuilder ()
instr prim pos = do
    st <- get
    case st of
      BodyState{failed=True}  -> do -- ignore if we've already failed
        logBuild $ "  Failing branch:  ignoring instruction " ++ show prim
        return ()
      BodyState{failed=False,buildState=Unforked} -> do
        prim' <- argExpandedPrim prim
        outNaming <- gets outSubst
        logBuild $ "With outSubst " ++ simpleShowMap outNaming
        logBuild $ "Generating instr " ++ show prim ++ " -> " ++ show prim'
        instr' prim' pos
      _ ->
        shouldnt "instr in Forked context"


instr' :: Prim -> OptPos -> BodyBuilder ()
instr' prim@(PrimForeign "llvm" "move" []
           [val, argvar@ArgVar{argVarName=var, argVarFlow=flow}]) pos
  = do
    logBuild $ "  Expanding move(" ++ show val ++ ", " ++ show argvar ++ ")"
    unless (flow == FlowOut && argFlowDirection val == FlowIn) $
      shouldnt $ "move instruction with wrong flow" ++ show prim
    outVar <- gets (Map.findWithDefault var var . outSubst)
    addSubst outVar val
    -- XXX since we're recording the subst, so this instr will be removed later,
    -- can we just not generate it?
    rawInstr prim pos
    recordVarSet argvar
--     this is a bit of a hack to work around not threading a heap
--     through the code, which causes the compiler to try to reuse
--     the results of calls to alloc.  Since the mutate primitives
--     already have an output value, that should stop us from trying
--     to reuse modified structures or the results of calls to
--     access after a structure is modified, so alloc should be
--     the only problem that needs fixing.  We don't want to fix this
--     by threading a heap through, because it's fine to reorder calls
--     to alloc.
-- XXX can we git rid of this special case by making lpvm alloc "impure"?
instr' prim@(PrimForeign "lpvm" "alloc" [] [_,argvar]) pos = do
    logBuild "  Leaving alloc alone"
    rawInstr prim pos
    recordVarSet argvar
-- XXX can we get rid of this pseudo-instruction?
instr' prim@(PrimForeign "lpvm" "cast" []
             [from, to@ArgVar{argVarName=var, argVarFlow=flow}]) pos = do
    logBuild $ "  Expanding cast(" ++ show from ++ ", " ++ show to ++ ")"
    unless (argFlowDirection from == FlowIn && flow == FlowOut) $
        shouldnt "cast instruction with wrong flow"
    if argType from == argType to
    then instr' (PrimForeign "llvm" "move" [] [from, to]) pos
    else ordinaryInstr prim pos
instr' prim@(PrimForeign "lpvm" "load" _ [ArgGlobal info _, var]) pos = do
    logBuild $ "  Checking if we know the value of " ++ show info
    loaded <- gets globalsLoaded
    case Map.lookup info loaded of
        Just val -> do
            logBuild $ "  ... we do: " ++ show val
            instr' (PrimForeign "llvm" "move" [] [mkInput val, var]) pos
        Nothing -> do
            logBuild "  ... we don't"
            ordinaryInstr prim pos
instr' prim@(PrimForeign "lpvm" "store" _ [var, ArgGlobal info _]) pos = do
    logBuild $ "  Checking if we know the value of " ++ show info
            ++ " and it is the same as " ++ show var
    mbVal <- Map.lookup info <$> gets globalsLoaded
    logBuild $ " ... found value " ++ show mbVal
    case mbVal of
        Just val 
          | mkInput (canonicaliseArg var) == mkInput (canonicaliseArg val) -> do
            logBuild " ... it is" 
        _ -> do
            logBuild " ... it isn't" 
            ordinaryInstr prim pos
instr' prim pos = ordinaryInstr prim pos


ordinaryInstr :: Prim -> OptPos -> BodyBuilder ()
ordinaryInstr prim pos = do
    let (prim',newOuts) = splitPrimOutputs prim
    logBuild $ "Looking for computed instr " ++ show prim' ++ " ..."
    currSubExprs <- gets subExprs
    logBuild $ "  with subExprs = " ++ show currSubExprs
    match <- gets (Map.lookup prim' . subExprs)
    case match of
        Nothing -> do
            -- record prim executed (and other modes), and generate instr
            logBuild "not found"
            impurity <- lift $ primImpurity prim
            let gFlows = snd $ primArgs prim
            when (impurity <= Pure && gFlows == emptyGlobalFlows) 
                $ recordEntailedPrims prim
            rawInstr prim pos
            mapM_ recordVarSet $ primOutputs prim
        Just oldOuts -> do
            -- common subexpr: just need to record substitutions
            logBuild $ "found it; substituting "
                        ++ show oldOuts ++ " for " ++ show newOuts
            mapM_ (\(newOut,oldOut) ->
                    instr' (PrimForeign "llvm" "move" []
                              [mkInput oldOut, newOut])
                    Nothing)
                  $ zip newOuts oldOuts



-- | Invert an output arg to be an input arg.
mkInput :: PrimArg -> PrimArg
mkInput (ArgVar name ty _ _ lst) =
    ArgVar name ty FlowIn Ordinary False
mkInput arg@ArgInt{} = arg
mkInput arg@ArgFloat{} = arg
mkInput arg@ArgString{} = arg
mkInput arg@ArgChar{} = arg
mkInput arg@ArgProcRef{} = arg
mkInput (ArgUnneeded _ ty) = ArgUnneeded FlowIn ty
mkInput arg@ArgGlobal{} = arg
mkInput arg@ArgUndef{} = arg


argExpandedPrim :: Prim -> BodyBuilder Prim
argExpandedPrim call@(PrimCall id pspec args gFlows) = do
    args' <- mapM expandArg args
    params <- lift $ primProtoParams <$> getProcPrimProto pspec
    unless (sameLength args' params) $
        shouldnt $ "arguments in call " ++ show call
                   ++ " don't match params " ++ show params
    args'' <- zipWithM (transformUnneededArg $ zip params args) params args'
    return $ PrimCall id pspec args'' gFlows
argExpandedPrim call@(PrimHigher id fn args) = do
    logBuild $ "Expanding Higher call " ++ show call       
    fn' <- expandArg fn
    case fn' of
        ArgProcRef pspec clsd _ -> do 
            pspec' <- fromMaybe pspec <$> lift (maybeGetClosureOf pspec)
            logBuild $ "As first-order call to " ++ show pspec'
            params <- lift $ getPrimParams pspec'
            let args' = zipWith (setArgType . primParamType) params args
            gFlows <- lift $ getProcGlobalFlows pspec
            argExpandedPrim $ PrimCall id pspec' (clsd ++ args') gFlows
        _ -> do
            logBuild $ "Leaving as higher call to " ++ show fn'       
            args' <- mapM expandArg args
            return $ PrimHigher id fn' args'
argExpandedPrim (PrimForeign lang nm flags args) = do
    args' <- mapM expandArg args
    return $ simplifyForeign lang nm flags args'


-- |Replace any arguments corresponding to unneeded parameters with
--  ArgUnneeded.  For unneeded *output* parameters, there must be an
--  input with the same name.  We must set the output argument variable
--  to the corresponding input argument, so the value is defined.
transformUnneededArg :: [(PrimParam,PrimArg)] -> PrimParam -> PrimArg
                     -> BodyBuilder PrimArg
transformUnneededArg pairs
    PrimParam{primParamInfo=ParamInfo{paramInfoUnneeded=True},
               primParamFlow=flow, primParamType=typ, primParamName=name}
    arg = do
        logBuild $ "Marking unneeded argument " ++ show arg
        when (flow == FlowOut) $ do
            case List.filter
                 (\(p,a)-> primParamName p == name && primParamFlow p == FlowIn)
                 pairs of
              []      -> shouldnt $ "No input param matching output "
                                    ++ show name
              [(_,a)] -> do
                logBuild $ "Adding move instruction for unneeded output "
                           ++ show arg
                instr' (PrimForeign "llvm" "move" [] [a, arg]) Nothing
              _       -> shouldnt $ "Multiple input params match output "
                                    ++ show name
        return $ ArgUnneeded flow typ
transformUnneededArg _ _ arg = return arg


-- |Construct a fake version of a Prim instruction containing only its
-- inputs, and with inessential parts canonicalised away.  Also return the
-- outputs of the instruction.
splitPrimOutputs :: Prim -> (Prim, [PrimArg])
splitPrimOutputs prim =
    let (args, gFlows) = primArgs prim
        (inArgs,outArgs) = splitArgsByMode args 
    in  (replacePrimArgs prim (canonicaliseArg <$> inArgs) gFlows, outArgs)


-- |Returns a list of all output arguments of the input Prim
primOutputs :: Prim -> [PrimArg]
primOutputs prim =
    List.filter ((==FlowOut) . argFlowDirection) $ fst $ primArgs prim


-- |Add a binding for a variable. If that variable is an output for the
--  proc being defined, also add an explicit assignment to that variable.
addSubst :: PrimVarName -> PrimArg -> BodyBuilder ()
addSubst var val = do
    logBuild $ "      adding subst " ++ show var ++ " -> " ++ show val
    modify (\s -> s { currSubst = Map.insert var val $ currSubst s })
    subst <- gets currSubst
    logBuild $ "      new subst = " ++ show subst


-- |Record that the specified arg (which must be a variable) has been set.
recordVarSet :: PrimArg -> BodyBuilder ()
recordVarSet ArgVar{argVarName=nm, argVarFlow=FlowOut} =
    modify (\s -> s { blockDefs = Set.insert nm $ blockDefs s })
recordVarSet (ArgUnneeded FlowOut _) = return ()
recordVarSet arg =
    shouldnt $ "recordVarSet of non-output argument " ++ show arg

-- |Record all instructions equivalent to the input prim in the lookup table,
--  so if we later see an equivalent instruction we don't repeat it but
--  reuse the already-computed outputs.  This implements common subexpression
--  elimination.  It can also handle optimisations like recognizing the
--  reconstruction of a deconstructed value, and accounts for commutative
--  operations and inverse operations.
recordEntailedPrims :: Prim -> BodyBuilder ()
recordEntailedPrims prim = do
    instrPairs <- (splitPrimOutputs prim:) <$> lift (instrConsequences prim)
    logBuild $ "Recording computed instrs"
              ++ List.concatMap
                  (\(p,o)-> "\n        " ++ show p ++ " -> " ++ show o)
                  instrPairs
    modify (\s -> s {subExprs = List.foldr (uncurry Map.insert) (subExprs s)
                                instrPairs})


-- |Return a list of instructions that have effectively already been
--  computed, mostly because they are inverses of instructions already
--  computed, or because of commutativity.
--  XXX Doesn't yet handle multiple modes for PrimCalls
instrConsequences :: Prim -> Compiler [(Prim,[PrimArg])]
instrConsequences prim =
   List.map (mapFst canonicalisePrim) <$> instrConsequences' prim

instrConsequences' :: Prim -> Compiler [(Prim,[PrimArg])]
instrConsequences' (PrimForeign "lpvm" "cast" flags [a1,a2]) =
    return [(PrimForeign "lpvm" "cast" flags [a2], [a1])]
-- XXX this doesn't handle mutate to other fields leaving value unchanged
instrConsequences'
    (PrimForeign "lpvm" "mutate" [] [_,addr,offset,_,size,startOffset,val]) =
    return [(PrimForeign "lpvm" "access" []
            [addr,offset,size,startOffset], [val])]
-- XXX handle flags
instrConsequences'
    (PrimForeign "lpvm" "access" [] [struct,offset,size,startOffset,val]) =
    return [(PrimForeign "lpvm" "mutate" []
            [struct,offset,ArgInt 1 intType,size,startOffset, val], [struct]),
            (PrimForeign "lpvm" "mutate" []
            [struct,offset,ArgInt 0 intType,size,startOffset, val], [struct])]
instrConsequences' (PrimForeign "llvm" "add" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "sub" flags [a3,a2], [a1]),
            (PrimForeign "llvm" "sub" flags [a3,a1], [a2]),
            (PrimForeign "llvm" "add" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "sub" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "add" flags [a3,a2], [a1]),
            (PrimForeign "llvm" "add" flags [a2,a3], [a1]),
            (PrimForeign "llvm" "sub" flags [a1,a3], [a2])]
instrConsequences' (PrimForeign "llvm" "mul" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "mul" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "fadd" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "fadd" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "fmul" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "fmul" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "and" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "and" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "or" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "or" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_eq" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_eq" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_ne" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_ne" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_slt" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_sgt" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_sgt" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_slt" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_ult" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_ugt" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_ugt" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_ult" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_sle" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_sge" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_sge" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_sle" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_ule" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_uge" flags [a2,a1], [a3])]
instrConsequences' (PrimForeign "llvm" "icmp_uge" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp_ule" flags [a2,a1], [a3])]
instrConsequences' _ = return []



-- |Unconditionally add an instr to the current body
rawInstr :: Prim -> OptPos -> BodyBuilder ()
rawInstr prim pos = do
    logBuild $ "---- adding instruction " ++ show prim
    validateInstr prim
    updateGlobalsLoaded prim pos
    modify $ addInstrToState (maybePlace prim pos)



splitArgsByMode :: [PrimArg] -> ([PrimArg], [PrimArg])
splitArgsByMode = List.partition ((==FlowIn) . argFlowDirection)


canonicalisePrim :: Prim -> Prim
canonicalisePrim (PrimCall id nm args gFlows) =
    PrimCall id nm (canonicaliseArg . mkInput <$> args) gFlows
canonicalisePrim (PrimHigher id var args) =
    PrimHigher id (canonicaliseArg $ mkInput var) $ canonicaliseArg . mkInput <$> args
canonicalisePrim (PrimForeign lang op flags args) =
    PrimForeign lang op flags $ List.map (canonicaliseArg . mkInput) args


-- |Standardise unimportant info in an arg, so that it is equal to any
--  other arg with the same content.
canonicaliseArg :: PrimArg -> PrimArg
canonicaliseArg ArgVar{argVarName=nm, argVarFlow=fl} =
    ArgVar nm AnyType fl Ordinary False
canonicaliseArg (ArgProcRef ms as _) = 
    ArgProcRef ms (canonicaliseArg <$> as) AnyType
canonicaliseArg (ArgInt v _)        = ArgInt v AnyType
canonicaliseArg (ArgFloat v _)      = ArgFloat v AnyType
canonicaliseArg (ArgString v r _)   = ArgString v r AnyType
canonicaliseArg (ArgChar v _)       = ArgChar v AnyType
canonicaliseArg (ArgGlobal info _)  = ArgGlobal info AnyType
canonicaliseArg (ArgUnneeded dir _) = ArgUnneeded dir AnyType
canonicaliseArg (ArgUndef _)        = ArgUndef AnyType


validateInstr :: Prim -> BodyBuilder ()
validateInstr p@(PrimCall _ _ args _) = mapM_ (validateArg p) args
validateInstr p@(PrimHigher _ fn args) = mapM_ (validateArg p) $ fn:args
validateInstr p@(PrimForeign _ _ _ args) = mapM_ (validateArg p) args


validateArg :: Prim -> PrimArg -> BodyBuilder ()
validateArg instr ArgVar{argVarType=ty} = validateType ty instr
validateArg instr (ArgInt    _ ty)      = validateType ty instr
validateArg instr (ArgFloat  _ ty)      = validateType ty instr
validateArg instr (ArgString _ _ ty)    = validateType ty instr
validateArg instr (ArgChar   _ ty)      = validateType ty instr
validateArg instr (ArgProcRef _ _ ty)   = validateType ty instr
validateArg instr (ArgGlobal _ ty)      = validateType ty instr
validateArg instr (ArgUnneeded _ ty)    = validateType ty instr
validateArg instr (ArgUndef ty)         = validateType ty instr


validateType :: TypeSpec -> Prim -> BodyBuilder ()
validateType InvalidType instr =
    shouldnt $ "InvalidType in argument of " ++ show instr
validateType _ instr = return ()


addInstrToState :: Placed Prim -> BodyState -> BodyState
addInstrToState ins st@BodyState{buildState=Unforked} =
    st { currBuild = ins:currBuild st}
-- XXX merge these two equations
addInstrToState ins st@BodyState{buildState=bld@Forked{complete=False,
                                                       bodies=bods}} =
    st { buildState = bld {bodies=List.map (addInstrToState ins) bods} }
addInstrToState ins st@BodyState{buildState=bld@Forked{complete=True,
                                                       bodies=bods}} =
    st { buildState = bld {bodies=List.map (addInstrToState ins) bods} }


-- |Return the current ultimate value of the specified variable name and type
expandVar :: PrimVarName -> TypeSpec -> BodyBuilder PrimArg
expandVar var ty = expandArg $ ArgVar var ty FlowIn Ordinary False


-- |Return the current ultimate value of the input argument.
expandArg :: PrimArg -> BodyBuilder PrimArg
expandArg arg@ArgVar{argVarName=var, argVarFlow=FlowIn} = do
    var' <- gets (Map.lookup var . currSubst)
    let ty = argVarType arg
    let var'' = setArgType ty <$> var' 
    logBuild $ "Expanded " ++ show var ++ " to " ++ show var''
    maybe (return arg) expandArg var''
expandArg arg@ArgVar{argVarName=var, argVarFlow=FlowOut} = do
    var' <- gets (Map.findWithDefault var var . outSubst)
    when (var /= var')
      $ logBuild $ "Replaced output variable " ++ show var
                   ++ " with " ++ show var'
    return arg{argVarName=var'}
expandArg arg@(ArgProcRef ps as ty) = do 
    as' <- mapM expandArg as
    return $ ArgProcRef ps as' ty
expandArg arg = return arg


updateGlobalsLoaded :: Prim -> OptPos -> BodyBuilder ()
updateGlobalsLoaded prim pos = do
    loaded <- gets globalsLoaded
    case prim of
        PrimForeign "lpvm" "load" _ [ArgGlobal info _, var] ->
            modify $ \s -> s{globalsLoaded=Map.insert info var loaded}
        PrimForeign "lpvm" "store" _ [var, ArgGlobal info _] ->
            modify $ \s -> s{globalsLoaded=Map.insert info var loaded}
        _ -> do
            let gFlows = snd $ primArgs prim
            logBuild $ "Call has global flows: " ++ show gFlows
            let filter info _ = not $ hasGlobalFlow gFlows FlowOut info
            modify $ \s -> s {globalsLoaded=Map.filterWithKey filter loaded}
    loaded' <- gets globalsLoaded
    when (loaded /= loaded') $ do
        logBuild $ "Globals Loaded: " ++ simpleShowMap loaded
        logBuild $ "             -> " ++ simpleShowMap loaded' 
                    

----------------------------------------------------------------
--                              Constant Folding
----------------------------------------------------------------

-- |Transform primitives with all inputs known into a move instruction by
--  performing the operation at compile-time.
simplifyForeign ::  String -> ProcName -> [Ident] -> [PrimArg] -> Prim
simplifyForeign "llvm" op flags args = simplifyOp op flags args
simplifyForeign lang op flags args = PrimForeign lang op flags args


-- | Simplify and canonicalise llvm instructions where possible. This
--   handles constant folding and simple (single-operation) algebraic
--   simplifications (left and right identities and annihilators).
--   Commutative ops are canonicalised by putting the smaller argument
--   first, but only for integer ops.  Integer inequalities are
--   canonicalised by putting smaller argument first and flipping
--   comparison if necessary.
simplifyOp :: ProcName -> [Ident] -> [PrimArg] -> Prim
-- Integer ops
simplifyOp "add" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1+n2) ty) output
simplifyOp "add" _ [ArgInt 0 ty, arg, output] =
  primMove arg output
simplifyOp "add" _ [arg, ArgInt 0 ty, output] =
  primMove arg output
simplifyOp "add" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "add" flags [arg2, arg1, output]
simplifyOp "sub" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1-n2) ty) output
simplifyOp "sub" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "mul" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1*n2) ty) output
simplifyOp "mul" _ [ArgInt 1 ty, arg, output] =
  primMove arg output
simplifyOp "mul" _ [arg, ArgInt 1 ty, output] =
  primMove arg output
simplifyOp "mul" _ [ArgInt 0 ty, _, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "mul" _ [_, ArgInt 0 ty, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "mul" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "mul" flags [arg2, arg1, output]
simplifyOp "div" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1 `div` n2) ty) output
simplifyOp "div" _ [arg, ArgInt 1 _, output] =
  primMove arg output
-- Bitstring ops
simplifyOp "and" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 .&. fromIntegral n2) ty) output
simplifyOp "and" _ [ArgInt 0 ty, _, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "and" _ [_, ArgInt 0 ty, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "and" _ [ArgInt (-1) _, arg, output] =
  primMove arg output
simplifyOp "and" _ [arg, ArgInt (-1) _, output] =
  primMove arg output
simplifyOp "and" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "and" flags [arg2, arg1, output]
simplifyOp "or" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 .|. fromIntegral n2) ty) output
simplifyOp "or" _ [ArgInt (-1) ty, _, output] =
  primMove (ArgInt (-1) ty) output
simplifyOp "or" _ [_, ArgInt (-1) ty, output] =
  primMove (ArgInt (-1) ty) output
simplifyOp "or" _ [ArgInt 0 _, arg, output] =
  primMove arg output
simplifyOp "or" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "or" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "or" flags [arg2, arg1, output]
simplifyOp "xor" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 `xor` fromIntegral n2) ty) output
simplifyOp "xor" _ [ArgInt 0 _, arg, output] =
  primMove arg output
simplifyOp "xor" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "xor" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "xor" flags [arg2, arg1, output]
simplifyOp "shl" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1 `shiftL` fromIntegral n2) ty) output
simplifyOp "shl" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "shl" _ [arg@(ArgInt 0 _), _, output] =
  primMove arg output
simplifyOp "ashr" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1 `shiftR` fromIntegral n2) ty) output
simplifyOp "ashr" _ [arg, ArgInt 0 _, output] =
  primMove arg output
-- XXX Need to convert both to unsigned before shifting
-- simplifyOp "lshr" _ [ArgInt n1 ty, ArgInt n2 _, output] =
--   primMove (ArgInt (n1 `shiftR` fromIntegral n2) ty) output
simplifyOp "lshr" _ [arg, ArgInt 0 _, output] =
  primMove arg output
-- Integer comparisons, including special handling of unsigned comparison to 0
simplifyOp "icmp_eq" _ [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1==n2) output
simplifyOp "icmp_eq" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_eq" flags [arg2, arg1, output]
simplifyOp "icmp_ne" _ [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1/=n2) output
simplifyOp "icmp_ne" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_ne" flags [arg2, arg1, output]
simplifyOp "icmp_slt" _ [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1<n2) output
simplifyOp "icmp_slt" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_sgt" flags [arg2, arg1, output]
simplifyOp "icmp_sle" _ [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1<=n2) output
simplifyOp "icmp_sle" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_sge" flags [arg2, arg1, output]
simplifyOp "icmp_sgt" _ [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1>n2) output
simplifyOp "icmp_sgt" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_slt" flags [arg2, arg1, output]
simplifyOp "icmp_sge" _ [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1>=n2) output
simplifyOp "icmp_sge" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_sle" flags [arg2, arg1, output]
simplifyOp "icmp_ult" _ [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'<n2') output
simplifyOp "icmp_ult" _ [_, ArgInt 0 _, output] = -- nothing is < 0
  primMove (ArgInt 0 boolType) output
simplifyOp "icmp_ult" flags [a1, ArgInt 1 ty, output] = -- only 0 is < 1
  PrimForeign "llvm" "icmp_eq" flags [a1,ArgInt 0 ty,output]
simplifyOp "icmp_ult" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_ugt" flags [arg2, arg1, output]
simplifyOp "icmp_ule" _ [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'<=n2') output
simplifyOp "icmp_ule" _ [ArgInt 0 _, _, output] = -- 0 is <= everything
  primMove (ArgInt 1 boolType) output
simplifyOp "icmp_ule" flags [ArgInt 1 ty, a2, output] = -- 1 is <= all but 0
  PrimForeign "llvm" "icmp_ne" flags [ArgInt 0 ty,a2,output]
simplifyOp "icmp_ule" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_uge" flags [arg2, arg1, output]
simplifyOp "icmp_ugt" _ [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'>n2') output
simplifyOp "icmp_ugt" _ [ArgInt 0 _, _, output] = -- 0 is > nothing
  primMove (ArgInt 0 boolType) output
simplifyOp "icmp_ugt" flags [ArgInt 1 ty, a2, output] = -- 1 is > only 0
  PrimForeign "llvm" "icmp_eq" flags [ArgInt 0 ty,a2,output]
simplifyOp "icmp_ugt" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_ult" flags [arg2, arg1, output]
simplifyOp "icmp_uge" _ [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'>=n2') output
simplifyOp "icmp_uge" _ [_, ArgInt 0 _, output] = -- everything is >= 0
  primMove (ArgInt 1 boolType) output
simplifyOp "icmp_uge" flags [a1, ArgInt 1 ty, output] = -- all but 0 is >= 1
  PrimForeign "llvm" "icmp_ne" flags [a1,ArgInt 0 ty,output]
simplifyOp "icmp_uge" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp_ule" flags [arg2, arg1, output]
-- Float ops
simplifyOp "fadd" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1+n2) ty) output
simplifyOp "fadd" _ [ArgFloat 0 _, arg, output] =
  primMove arg output
simplifyOp "fadd" _ [arg, ArgFloat 0 _, output] =
  primMove arg output
simplifyOp "fsub" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1-n2) ty) output
simplifyOp "fsub" _ [arg, ArgFloat 0 _, output] =
  primMove arg output
simplifyOp "fmul" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1*n2) ty) output
simplifyOp "fmul" _ [arg, ArgFloat 1 _, output] =
  primMove arg output
simplifyOp "fmul" _ [ArgFloat 1 _, arg, output] =
  primMove arg output
-- We don't handle float * 0.0 because of the semantics of IEEE floating mult.
simplifyOp "fdiv" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1/n2) ty) output
simplifyOp "fdiv" _ [arg, ArgFloat 1 _, output] =
  primMove arg output
-- Float comparisons
simplifyOp "fcmp_eq" _ [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1==n2) output
simplifyOp "fcmp_ne" _ [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1/=n2) output
simplifyOp "fcmp_slt" _ [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1<n2) output
simplifyOp "fcmp_sle" _ [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1<=n2) output
simplifyOp "fcmp_sgt" _ [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1>n2) output
simplifyOp "fcmp_sge" _ [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1>=n2) output
simplifyOp name flags args = PrimForeign "llvm" name flags args


boolConstant :: Bool -> PrimArg
boolConstant bool = ArgInt (fromIntegral $ fromEnum bool) boolType

----------------------------------------------------------------
--                  Fusing Forks in BodyStates
--
-- BodyStates allow code to follow a branch; this code injects subsequent code
-- at the end of previous code.  Crucially, it also uses information about fixed
-- variable values from earlier forks to specialise following forks.  In
-- particular, when appending a fork to the end of an earlier fork, it is often
-- possible to determine the branch that will be selected in the later fork,
-- avoiding the need for the test.  This has the effect of fusing successive
-- forks on the same variable into a single fork.
--
-- This code ensures that code is compatible with LPVM form by producing a
-- BodyState that has no parent, and where all the bodies recursively within the
-- BuildState also have no parent.
----------------------------------------------------------------

-- | Recursively fuse Bodystate, as described above.
fuseBodies :: BodyState -> Compiler BodyState
fuseBodies st@BodyState{parent=Nothing, buildState=bst} = do
    logMsg BodyBuilder $ "Fusing origin bodyState:" ++ fst (showState 4 st)
    bst' <- fuseBranches bst
    let st' = st {buildState = bst'}
    logMsg BodyBuilder $ "Fused origin state:" ++ fst (showState 4 st')
    return st'
fuseBodies st@BodyState{parent=Just par, buildState=bst} = do
    logMsg BodyBuilder $ "Fusing child bodyState:" ++ fst (showState 4 st)
    par' <- fuseBodies par
    st' <- addBodyContinuation par' $ st {parent=Nothing}
    logMsg BodyBuilder $ "Fused child state:" ++ fst (showState 4 st')
    return st'


fuseBranches :: BuildState -> Compiler BuildState
fuseBranches Unforked = return Unforked
fuseBranches bst@Forked{forkingVar=var,bodies=bods} = do
    logMsg BodyBuilder $ "Fusing branches of fork on " ++ show var
    bods' <- mapM fuseBodies $ bodies bst
    return $ bst {bodies=bods'}


-- | Add the second BodyState at the end of the first.  The second BodyState is
-- known to be a tree, ie, its parent is Nothing, and its branches, if it has
-- any, have been fused.
addBodyContinuation :: BodyState -> BodyState -> Compiler BodyState
addBodyContinuation _ next@BodyState{parent=Just _} =
    shouldnt $ "addBodyContinuation with non-singular second argument:"
               ++ fst (showState 4 next)
addBodyContinuation prev@BodyState{buildState=Unforked, currBuild=bld,
                                   currSubst=subst, blockDefs=defs,
                                   outSubst=osubst} next = do
    logMsg BodyBuilder $ "Adding state:" ++ fst (showState 4 next)
    logMsg BodyBuilder $ "... after unforked body:" ++ fst (showState 4 prev)
    addSelectedContinuation bld subst defs osubst next
addBodyContinuation prev@BodyState{buildState=Forked{}} next = do
    logMsg BodyBuilder $ "Adding state:" ++ fst (showState 4 next)
    logMsg BodyBuilder $ "... after forked body:" ++ fst (showState 4 prev)
    let build = buildState prev
    bods <- mapM (`addBodyContinuation` next) $ bodies build
    return $ prev {buildState = build {bodies = bods}}


-- | Add the appropriate branch(es) to follow the specified list of prims, which
-- includes both the prims of the previous unforked body and the unforked part
-- of the following 
addSelectedContinuation :: [Placed Prim] -> Substitution -> Set PrimVarName
                        -> VarSubstitution -> BodyState -> Compiler BodyState
                        -- XXX Must merge subst with currSubst of st
addSelectedContinuation prevPrims subst defs osubst
                        st@BodyState{buildState=Unforked} = do
    let subst'  = Map.union (currSubst st) subst
    let defs'   = Set.union (blockDefs st) defs
    let oSubst' = Map.union (outSubst st)  osubst
    let st' = st { currBuild = currBuild st ++ prevPrims
                 , currSubst = subst'
                 , blockDefs = defs'
                 , outSubst  = oSubst' }
    logMsg BodyBuilder $ "Adding unforked continuation produces:"
                         ++ fst (showState 4 st')
    return st'
addSelectedContinuation prevPrims subst defs osubst
                        st@BodyState{buildState=bst@Forked{}} = do
    let subst'  = Map.union (currSubst st) subst
    let defs'   = Set.union (blockDefs st) defs
    let osubst' = Map.union (outSubst st)  osubst
    case selectedBranch subst bst of
        Nothing -> do
            bst <- fuseBranches $ buildState st
            let st' = st { currBuild  = currBuild st ++ prevPrims
                         , currSubst  = subst'
                         , blockDefs  = defs'
                         , outSubst   = osubst'
                         , buildState = bst }
            logMsg BodyBuilder $ "No fork selection possible, producing:"
                         ++ fst (showState 4 st')
            return st'
        Just branchNum -> do
            let selectedBranch = revSelectElt branchNum $ bodies bst
            logMsg BodyBuilder $ "Selected branch " ++ show branchNum
            selectedBranch' <- fuseBodies selectedBranch
            addSelectedContinuation (currBuild st ++ prevPrims)
                                    subst' defs' osubst' selectedBranch'


-- |Given a variable substitution, determine which branch will be selected,
-- if possible.
selectedBranch :: Substitution -> BuildState -> Maybe Integer
selectedBranch subst Unforked = Nothing
selectedBranch subst Forked{knownVal=known, forkingVar=var} =
    known `orElse` (Map.lookup var subst >>= argIntegerValue)    


----------------------------------------------------------------
--                  Reassembling the ProcBody
--
-- Once we've built up a BodyState, this code assembles it into a new ProcBody.
-- While we're at it, we also mark the last use of each variable, eliminate
-- calls that don't produce any output needed later in the body, and eliminate
-- any move instructions that moves a variable defined in the same block as the
-- move and not used after the move.  Most other move instructions were removed
-- while building BodyState, but that approach cannot eliminate moves to output
-- parameters.
----------------------------------------------------------------

currBody :: ProcBody -> BodyState 
         -> Compiler (Int,Set PrimVarName,ProcBody)
currBody body st@BodyState{tmpCount=tmp} = do
    logMsg BodyBuilder $ "Now reconstructing body with usedLater = "
      ++ intercalate ", " (show <$> Map.keys (outSubst st))
    st' <- execStateT (rebuildBody st)
           $ BkwdBuilderState (Map.keysSet $ outSubst st) Nothing Map.empty
                              0 Set.empty body
    let BkwdBuilderState{bkwdUsedLater=usedLater,
                         bkwdFollowing=following} = st'
    logMsg BodyBuilder ">>>> Finished rebuilding a proc body"
    logMsg BodyBuilder "     Final state:"
    logMsg BodyBuilder $ showBlock 5 following
    return (tmp, usedLater, following)


-- |Another monad, this one for rebuilding a proc body bottom-up.
type BkwdBuilder = StateT BkwdBuilderState Compiler

-- |BkwdBuilderState is used to store context info while building a ProcBody
-- backwards from a BodyState, itself the result of rebuilding a ProcBody
-- forwards.  Because construction runs backwards, the state mostly holds
-- information about the following code.
data BkwdBuilderState = BkwdBuilderState {
      bkwdUsedLater    :: Set PrimVarName, -- ^Variables used later in computation
      bkwdBranchesUsedLater :: Maybe [Set PrimVarName],
                                           -- ^The usedLater set for each
                                           -- following branch, used for fused
                                           -- branches.
      bkwdRenaming     :: VarSubstitution, -- ^Variable substitution to apply
      bkwdTmpCount     :: Int,             -- ^Highest temporary variable number
      bkwdGlobalStored :: Set GlobalInfo,  -- ^The set of globals we have 
                                           -- recently stored
      bkwdFollowing    :: ProcBody         -- ^Code to come later
      } deriving (Eq,Show)


rebuildBody :: BodyState -> BkwdBuilder ()
rebuildBody st@BodyState{parent=Just par} =
    shouldnt $ "Body parent left by fusion: " ++ fst (showState 4 par)
rebuildBody st@BodyState{currBuild=prims, currSubst=subst, blockDefs=defs,
                         buildState=bldst, parent=Nothing} = do
    usedLater <- gets bkwdUsedLater
    following <- gets bkwdFollowing
    logBkwd $ "Rebuilding body:" ++ fst (showState 8 st)
              ++ "\nwith currSubst = " ++ simpleShowMap subst
              ++ "\n     usedLater = " ++ simpleShowSet usedLater
    case bldst of
      Unforked -> nop
      Forked{complete=False} ->
        shouldnt "Building proc body for bodystate with incomplete fork"
      Forked var ty fixedval fused bods True ->
        case fixedval of
          Just val ->
            rebuildBody $ revSelectElt val bods
          Nothing -> do
            -- XXX Perhaps we should generate a new proc for the parent par in
            -- cases where it's more than a few prims.
            sts <- mapM (rebuildBranch subst) $ reverse bods
            usedLater' <- gets bkwdUsedLater
            let usedLaters = bkwdUsedLater <$> sts
            let usedLater'' = List.foldr Set.union usedLater' usedLaters
            let branchesUsedLater =
                  if fused
                  then Just usedLaters
                  else Nothing
            logBkwd $ "Switch on " ++ show var
                      ++ " with usedLater " ++ simpleShowSet usedLater''
            logBkwd $ "branchesUsedLater = "
                      ++ show branchesUsedLater
            let lastUse = Set.notMember var usedLater''
            let usedLater''' = Set.insert var usedLater''
            let tmp = maximum $ List.map bkwdTmpCount sts
            let followingBranches = List.map bkwdFollowing sts
            let gStored = List.foldr1 Set.intersection (bkwdGlobalStored <$> sts)
            put $ BkwdBuilderState usedLater''' branchesUsedLater
                  Map.empty tmp gStored
                  $ ProcBody [] $ PrimFork var ty lastUse followingBranches
    mapM_ (placedApply (bkwdBuildStmt defs)) prims
    finalUsedLater <- gets bkwdUsedLater
    logBkwd $ "Finished rebuild with usedLater = " ++ show finalUsedLater


-- |Select the element of bods specified by num
selectElt :: Integral a => a -> [b] -> b
selectElt num bods =
    if num' >= 0 && num' < length bods
    then bods !! num'
    else shouldnt $ "Out-of-bounds fixed value in fork " ++ show num'
  where num' = fromIntegral num


-- |Select the element of bods, which is reversed, by num
revSelectElt :: Integral a => a -> [b] -> b
revSelectElt num revBods =
    selectElt (length revBods - 1 - fromIntegral num) revBods


rebuildBranch :: Substitution -> BodyState -> BkwdBuilder BkwdBuilderState
rebuildBranch subst bod = do
    bkwdSt <- get
    lift $ execStateT (rebuildBody bod) bkwdSt


bkwdBuildStmt :: Set PrimVarName -> Prim -> OptPos -> BkwdBuilder ()
bkwdBuildStmt defs prim pos = do
    usedLater <- gets bkwdUsedLater
    renaming <- gets bkwdRenaming
    gStored <- gets bkwdGlobalStored
    logBkwd $ "  Rebuilding prim: " ++ show prim
              ++ "\n    with usedLater   = " ++ show usedLater
              ++ "\n    and bkwdRenaming = " ++ simpleShowMap renaming
              ++ "\n    and defs         = " ++ simpleShowSet defs
              ++ "\n    and globalStored = " ++ simpleShowSet gStored
    let (args, gFlows) = primArgs prim
    args' <- mapM renameArg args
    logBkwd $ "    renamed args = " ++ show args'
    case (prim,args') of
      (PrimForeign "llvm" "move" [] _, [ArgVar{argVarName=fromVar},
                                        ArgVar{argVarName=toVar}])
          | Set.notMember fromVar usedLater && Set.member fromVar defs -> 
              modify $ \s -> s { bkwdRenaming = Map.insert fromVar toVar 
                                              $ bkwdRenaming s }
      (PrimForeign "lpvm" "store" [] _, [_, ArgGlobal info _]) 
          | info `Set.member` gStored -> return ()
          | otherwise -> do
              modify $ \s -> s { bkwdGlobalStored = Set.insert info gStored }
              bkwdBuildStmt' defs args' gFlows prim pos
      _ -> do 
          let filter info = not $ hasGlobalFlow gFlows FlowIn info
          modify $ \s -> s { bkwdGlobalStored = Set.filter filter gStored }
          bkwdBuildStmt' defs args' gFlows prim pos


bkwdBuildStmt' :: Set PrimVarName -> [PrimArg] -> GlobalFlows -> Prim -> OptPos -> BkwdBuilder ()
bkwdBuildStmt' defs args gFlows prim pos = do
    usedLater <- gets bkwdUsedLater
    let (ins, outs) = splitArgsByMode $ List.filter argIsVar $ flattenArgs args
    -- Filter out pure instructions that produce no needed outputs or out flowing
    -- globals
    purity <- lift $ primImpurity prim
    when (purity > Pure || any (`Set.member` usedLater) (argVarName <$> outs)
                        || not (USet.isEmpty $ globalFlowsOut gFlows))
      $ do
        -- XXX Careful:  probably shouldn't mark last use of variable passed
        -- as input argument more than once in the call
        let prim' = replacePrimArgs prim (markIfLastUse usedLater <$> args) gFlows
        logBkwd $ "    updated prim = " ++ show prim'
        let inVars = argVarName <$> ins
        let usedLater' = List.foldr Set.insert usedLater inVars
        st@BkwdBuilderState{bkwdFollowing=bd@ProcBody{bodyPrims=prims}} <- get
        put $ st { bkwdFollowing =
                      bd { bodyPrims     = maybePlace prim' pos:prims },
                           bkwdUsedLater = usedLater' }


renameArg :: PrimArg -> BkwdBuilder PrimArg
renameArg arg@ArgVar{argVarName=name} = do
    name' <- gets (Map.findWithDefault name name . bkwdRenaming)
    return $ arg {argVarName=name'}
renameArg (ArgProcRef ps args ts) = do
    args' <- mapM renameArg args
    return $ ArgProcRef ps args' ts
renameArg arg = return arg

flattenArgs :: [PrimArg] -> [PrimArg]
flattenArgs = concatMap flattenArg

flattenArg :: PrimArg -> [PrimArg]
flattenArg arg@(ArgProcRef _ as ts) = arg:flattenArgs as 
flattenArg arg = [arg]


markIfLastUse :: Set PrimVarName -> PrimArg -> PrimArg
markIfLastUse usedLater arg@ArgVar{argVarName=nm,argVarFlow=FlowIn} =
  arg {argVarFinal=Set.notMember nm usedLater}
markIfLastUse _ arg = arg


----------------------------------------------------------------
--                                  Logging
----------------------------------------------------------------

-- |Log a message, if we are logging body building activity.
logBuild :: String -> BodyBuilder ()
logBuild s = lift $ logMsg BodyBuilder s


-- |Log a message, if we are logging body building activity.
logBkwd :: String -> BkwdBuilder ()
logBkwd s = lift $ logMsg BodyBuilder s


-- | Log the current builder state
logState :: BodyBuilder ()
logState = do
    st <- get
    logBuild $ "     Current state:" ++ fst (showState 8 st)
    return ()


-- | Show the current builder state.  Since the builder builds upside down, we
-- start by showing the parent, then we show the current state.
showState :: Int -> BodyState -> (String,Int)
showState indent BodyState{parent=par, currBuild=revPrims, buildState=bld,
                           blockDefs=defs, forkConsts=consts,
                           currSubst=substs, globalsLoaded=loaded} =
    let (str  ,indent')   = maybe ("",indent)
                            (mapFst (++ (startLine indent ++ "----------")) 
                            . showState indent) par
        substStr          = startLine indent
                            ++ "# Substs: " ++ simpleShowMap substs
        globalStr         = startLine indent
                            ++ "# Loaded globals: " ++ simpleShowMap loaded
        str'              = showPlacedPrims indent' (reverse revPrims)
        sets              = if List.null revPrims
                            then ""
                            else startLine indent
                                 ++ "# Vars defined: "
                                 ++ simpleShowSet defs
        suffix            = case bld of
                              Forked{} ->
                                startLine indent
                                ++ "# Fusion consts: " ++ show consts
                              _ -> ""
        
        (str'',indent'') = showBuildState indent' bld
    in  (str ++ str' ++ substStr ++ sets ++ globalStr ++ str'' ++ suffix, indent'')


-- | Show the current part of a build state.
showBuildState :: Int -> BuildState -> (String,Int)
showBuildState indent Unforked = ("", indent)
showBuildState indent (Forked var ty val fused bodies False) =
    let intro = showSwitch indent var ty val fused
        content = showBranches indent 0 True $ reverse bodies
        indent' = indent + 4
    in  (intro++content,indent')
showBuildState indent (Forked var ty val fused bodies True) =
    let intro = showSwitch indent var ty val fused
        content = showBranches indent 0 False $ reverse bodies
    in  (intro++content,indent)


-- | Show a list of branches of a build state.
showBranches :: Int -> Int -> Bool -> [BodyState] -> String
showBranches indent bodyNum True [] = showCase indent bodyNum
showBranches indent bodyNum False [] = ""
showBranches indent bodyNum open (body:bodies) =
    showCase indent bodyNum
    ++ fst (showState (indent+4) body)
    ++ showBranches indent (bodyNum+1) open bodies


-- | Show a single branch of a build state
showCase indent bodyNum = startLine indent ++ show bodyNum ++ "::"


-- | Show the fork part of a build state
showSwitch indent var ty val fused =
    startLine indent ++ "case " ++ show var ++ ":" ++ show ty
    ++ (if fused then " (fused)" else " (not fused)")
    ++ maybe "" (\v-> " (=" ++ show v ++ ")") val
    ++ " of"


-- | Start a new line with the specified indent.
startLine :: Int -> String
startLine tab = '\n' : replicate tab ' '
