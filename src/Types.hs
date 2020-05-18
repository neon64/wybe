--  File     : Types.hs
--  Author   : Peter Schachte
--  Purpose  : Type checker/inferencer for Wybe
--  Copyright: (c) 2012 Peter Schachte.  All rights reserved.
--  License  : Licensed under terms of the MIT license.  See the file
--           : LICENSE in the root directory of this project.

-- |Support for type checking/inference.
module Types (validateModExportTypes, typeCheckMod, -- modeCheckMod,
              checkFullyTyped) where

import           AST
import           Control.Monad.State
import           Control.Monad.Extra
import           Data.Graph
import           Data.List           as List
import           Data.Map            as Map
import           Data.Maybe          as Maybe
import           Data.Set            as Set
import           Data.Tuple.Select
import           Data.Tuple.HT
import           Data.Foldable
import           Data.Functor
-- import           MonadUtils
import           Options             (LogSelection (Types))
-- import           Resources
import           Util
import           Snippets
import           Blocks              (llvmMapBinop, llvmMapUnop)

-- import           Debug.Trace


----------------------------------------------------------------
--           Validating Proc Parameter Type Declarations
----------------------------------------------------------------


-- |Check declared types of exported procs for the specified module.
-- This doesn't check that the types are correct vis-a-vis the
-- definition, just that the declared types are valid types, and it
-- updates the types to their fully-module-qualified versions.
validateModExportTypes :: ModSpec -> Compiler ()
validateModExportTypes thisMod = do
    logTypes $ "**** Validating parameter types in module " ++
           showModSpec thisMod
    reenterModule thisMod
    iface <- getModuleInterface
    procs <- getModuleImplementationField (Map.toAscList . modProcs)
    procs' <- mapM (uncurry validateProcDefsTypes) procs
    updateModImplementation (\imp -> imp { modProcs = Map.fromAscList procs'})
    _ <- reexitModule
    logTypes $ "**** Re-exiting module " ++ showModSpec thisMod


validateProcDefsTypes :: Ident -> [ProcDef] -> Compiler (Ident,[ProcDef])
validateProcDefsTypes name defs = do
    defs' <- mapM (validateProcDefTypes name) defs
    return (name, defs')


validateProcDefTypes :: Ident -> ProcDef -> Compiler ProcDef
validateProcDefTypes name def = do
    let public = procVis def == Public
    let pos = procPos def
    let proto = procProto def
    let params = procProtoParams proto
    logTypes $ "Validating def of " ++ name
    params' <- mapM (validateParamType name pos public) params
    return $ def { procProto = proto { procProtoParams = params' }}


validateParamType :: Ident -> OptPos -> Bool -> Param -> Compiler Param
validateParamType pname ppos public param = do
    let ty = paramType param
    checkDeclIfPublic pname ppos public ty
    logTypes $ "Checking type " ++ show ty ++ " of param " ++ show param
    ty' <- fromMaybe AnyType <$> lookupType ty ppos
    let param' = param { paramType = ty' }
    logTypes $ "Param is " ++ show param'
    return param'


checkDeclIfPublic :: Ident -> OptPos -> Bool -> TypeSpec -> Compiler ()
checkDeclIfPublic pname ppos public ty =
    when (public && ty == AnyType) $
        errmsg ppos $ "Public proc '" ++ pname ++
                        "' with undeclared parameter or return type"


----------------------------------------------------------------
--                       Supporting Type Errors
----------------------------------------------------------------

-- |Either something or some type errors
data MaybeErr t = OK t | Err [TypeError]
    deriving (Eq,Show)


-- |Return a list of the errors in the supplied MaybeErr
errList :: MaybeErr t -> [TypeError]
errList (OK _) = []
errList (Err lst) = lst


-- |Return a list of the payloads of all the OK elements of the input list
catOKs :: [MaybeErr t] -> [t]
catOKs lst = let toMaybe (OK a) =  Just a
                 toMaybe (Err _) = Nothing
             in  Maybe.mapMaybe toMaybe lst


-- |The reason a variable is given a certain type
data TypeError = ReasonParam ProcName Int OptPos
                   -- ^Formal param type/flow inconsistent
               | ReasonOutputUndef ProcName Ident OptPos
                   -- ^Output param not defined by proc body
               | ReasonResource ProcName Ident OptPos
                   -- ^Declared resource inconsistent
               | ReasonUndef ProcName ProcName OptPos
                   -- ^Call to unknown proc
               | ReasonNoMatch ProcName ProcName OptPos
                   -- ^Call with no matching definition
               | ReasonUninit ProcName VarName OptPos
                   -- ^Use of uninitialised variable
               | ReasonArgType ProcName Int OptPos
                   -- ^Actual param type inconsistent
               | ReasonCond OptPos
                   -- ^Conditional expression not bool
               | ReasonArgFlow ProcName Int OptPos
                   -- ^Input param with undefined argument variable
               | ReasonUndefinedFlow ProcName OptPos
                   -- ^Call argument flow does not match any definition
               | ReasonOverload [ProcSpec] OptPos
                   -- ^Multiple procs with same types/flows
               | ReasonAmbig ProcName OptPos [(VarName,[TypeSpec])]
                   -- ^Proc defn has ambiguous types
               | ReasonArity ProcName ProcName OptPos Int (Set Int)
                   -- ^Call to proc with wrong arity
               | ReasonUndeclared ProcName ProcProto OptPos
                   -- ^Public proc with some undeclared types and inferred proto
               | ReasonEqual Exp Exp OptPos
                   -- ^Expression types should be equal
               | ReasonDeterminism ProcSpec Determinism OptPos
                   -- ^Calling a semidet proc in a det context
               | ReasonForeignLanguage String String OptPos
                   -- ^Foreign call with bogus language
               | ReasonForeignArgType String Int OptPos
                   -- ^Foreign call with unknown argument type
               | ReasonForeignArity String Int Int OptPos
                   -- ^Foreign call with wrong arity
               | ReasonBadForeign String String OptPos
                   -- ^Unknown foreign llvm/lpvm instruction
               | ReasonResourceUndef ProcName Ident OptPos
                   -- ^Output resource not defined in proc body
               | ReasonResourceUnavail ProcName Ident OptPos
                   -- ^Input resource not available in proc call
               | ReasonWrongFamily Ident Int TypeFamily OptPos
                   -- ^LLVM instruction expected different argument family
               | ReasonIncompatible Ident TypeRepresentation
                 TypeRepresentation OptPos
                   -- ^Inconsistent arguments to binary LLVM instruction
               | ReasonWrongOutput Ident TypeRepresentation
                 TypeRepresentation OptPos
                   -- ^Wrong output type representation to LLVM instruction
               | ReasonBadMove TypeSpec TypeSpec OptPos
                   -- ^LLVM move with different arg types
               | ReasonForeignArgRep Ident Int TypeRepresentation
                 String OptPos
                   -- ^Foreign call with wrong argument type
               | ReasonShouldnt
                   -- ^This error should never happen
               deriving (Eq)


instance Show TypeError where
    show (ReasonParam name num pos) =
        makeMessage pos $
            "Type/flow error in definition of " ++ name ++
            ", parameter " ++ show num
    show (ReasonOutputUndef proc param pos) =
        makeMessage pos $
        "Output parameter " ++ param ++ " not defined by proc " ++ show proc
    show (ReasonResource name resName pos) =
            "Type/flow error in definition of " ++ name ++
            ", resource " ++ resName
    show (ReasonArgType name num pos) =
        makeMessage pos $
            "Type error in call to " ++ name ++ ", argument " ++ show num
    show (ReasonCond pos) =
        makeMessage pos
            "Conditional or test expression with non-boolean result"
    show (ReasonArgFlow name num pos) =
        makeMessage pos $
            "Uninitialised argument in call to " ++ name
            ++ ", argument " ++ show num
    show (ReasonUndefinedFlow name pos) =
        makeMessage pos $
            "No matching mode in call to " ++ name
    show (ReasonOverload pspecs pos) =
        makeMessage pos $
            "Ambiguous overloading: call could refer to:" ++
            List.concatMap (("\n    "++) . show) (reverse pspecs)
    show (ReasonAmbig procName pos varAmbigs) =
        makeMessage pos $
            "Type ambiguity in defn of " ++ procName ++ ":" ++
            concat ["\n    Variable '" ++ v ++ "' could be: " ++
                    intercalate ", " (List.map show typs)
                   | (v,typs) <- varAmbigs]
    show (ReasonUndef callFrom callTo pos) =
        makeMessage pos $
            "Call to unknown '" ++ callTo ++ "' in "
            ++ if callFrom == ""
               then "top-level statement"
               else "definition of '" ++ callFrom ++ "'"
    show (ReasonNoMatch callFrom callTo pos) =
        makeMessage pos $
            "Call to type incompatible '" ++ callTo ++ "' in "
            ++ if callFrom == ""
               then "top-level statement"
               else "'" ++ callFrom ++ "'"
    show (ReasonUninit callFrom var pos) =
        makeMessage pos $
            "Unknown variable/constant '" ++ var ++ "'"
    show (ReasonArity callFrom callTo pos callArity procArities) =
        makeMessage pos $
            (if callFrom == ""
             then "Toplevel call"
             else "Call from " ++ callFrom) ++
            " to " ++ callTo ++ " with " ++
            show callArity ++ " arguments, expected "
            ++ case show <$> Set.toAscList procArities of
                 []  -> shouldnt "empty list of arities in ReasonArity"
                 [n] -> n
                 as  -> intercalate ", " (init as) ++ " or " ++ (last as)
    show (ReasonUndeclared name proto pos) =
        makeMessage pos $
        "Public definition of '" ++ name ++ "' with some undeclared types,"
        ++ "\n Inferred: " ++ show proto
    show (ReasonEqual exp1 exp2 pos) =
        makeMessage pos $
        "Expressions must have compatible types:\n    "
        ++ show exp1 ++ "\n    "
        ++ show exp2
    show (ReasonDeterminism proc detism pos) =
        makeMessage pos $
        "Calling " ++ determinismName detism ++ " proc "
        ++ show proc ++ " in a det context"
    show (ReasonForeignLanguage lang instr pos) =
        makeMessage pos $
        "Foreign call '" ++ instr ++ "' with unknown language '" ++ lang ++ "'"
    show (ReasonForeignArgType instr argNum pos) =
        makeMessage pos $
        "Foreign call '" ++ instr ++ "' with unknown type in argument "
        ++ show argNum
    show (ReasonForeignArity instr actualArity expectedArity pos) =
        makeMessage pos $
        "Foreign call '" ++ instr ++ "' with arity " ++ show actualArity
        ++ "; should be " ++ show expectedArity
    show (ReasonBadForeign lang instr pos) =
        makeMessage pos $
        "Unknown " ++ lang ++ " instruction '" ++ instr ++ "'"
    show (ReasonResourceUndef proc res pos) =
        makeMessage pos $
        "Output resource " ++ res ++ " not defined by proc " ++ proc
    show (ReasonResourceUnavail proc res pos) =
        makeMessage pos $
        "Input resource " ++ res ++ " not available at call to proc " ++ proc
    show (ReasonWrongFamily instr argNum fam pos) =
        makeMessage pos $
        "LLVM instruction '" ++ instr ++ "' argument " ++ show argNum
        ++ ": expected " ++ show fam ++ " argument"
    show (ReasonIncompatible instr rep1 rep2 pos) =
        makeMessage pos $
        "LLVM instruction '" ++ instr ++ "' inconsistent arguments "
        ++ show rep1 ++ " and " ++ show rep2
    show (ReasonWrongOutput instr wrongRep rightRep pos) =
        makeMessage pos $
        "LLVM instruction '" ++ instr ++ "' wrong output "
        ++ show wrongRep ++ ", should be " ++ show rightRep
    show (ReasonBadMove inType outType pos) =
        makeMessage pos $
        "LLVM move instruction with incompatible types "
        ++ show inType ++ " and " ++ show outType
    show (ReasonForeignArgRep instr argNum wrongRep rightDesc pos) =
        makeMessage pos $
        "LLVM instruction '" ++ instr ++ "' argument " ++ show argNum
        ++ " is " ++ show wrongRep ++ ", should be " ++ rightDesc
    show ReasonShouldnt =
        makeMessage Nothing "Mysterious typing error"



----------------------------------------------------------------
--                           Type Assignments
----------------------------------------------------------------

-- |The state underlying the TypeChecker monad.  This contains the ProcDef of
-- the proc we are currently type checking, as well as the current Typing
data TypeCheckState = TypeCheckState {
      tcheckProcDef :: ProcDef,      -- ^The proc we're type checking
      tcheckTyping  :: Typing,       -- ^The typing we've deduced so far
      -- XXX don't check determinism here any more; that's done later in a
      -- full-fledged determinism analysis incorporating a value analysis.
      tcheckDetism  :: Determinism,  -- ^Determinism context of the current stmt
      tcheckBinding :: BindingState, -- ^Variables bound at the current stmt
      tcheckDelayed :: [(Set VarName,Placed Stmt)]
                                     -- ^Statements delayed pending var bindings
      }

-- |A variable type assignment (symbol table), with a list of type errors.  Also
-- contains bindings for type variables.
data Typing = Typing {
      typingDict :: Map VarName TypeSpec,     -- ^Type of each data var
      tvarDict   :: Map TypeVarName TypeSpec, -- ^Type of each type var
      typingErrs :: [TypeError],              -- ^Type errors found
      unresolved :: [Alternatives]            -- ^Unresolved call typings
      } deriving (Show,Eq)


-- |Represents one overloaded call, including all the variables whose types will
-- be determined by the call and all the alternative tuples (lists) of
-- types that they could be assigned.  This considers only types and not modes,
-- so we don't determine a particular ProcSpec at this point, only the types of
-- all the variables involved in the call.  The altVars list must be the same
-- length as each list in the altTypes set.
data Alternatives = Alternatives {
    altVars  :: [VarName],          -- ^Vars involved in the call
    altTypes :: Set [TypeSpec] -- ^Set of possible types for those vars
    } deriving (Show, Eq)


-- |A monad to carry a Type checking state.
type TypeChecker = StateT TypeCheckState Compiler


-- |Run a TypeChecker monad, specifying the proc whose definition is being
-- checked, and returning the result plus the final typing.
typeCheck :: ProcDef -> TypeChecker a -> Compiler (a,ProcDef,[TypeError])
typeCheck pdef checker = do
    (a,st) <- runStateT checker
              $ TypeCheckState pdef initTyping (procDetism pdef)
                initBindingState []
    return (a, tcheckProcDef st, typingErrs $ tcheckTyping st)


-- |Get some attribute of the proc being type checked.
getProcMember :: (ProcDef -> a) -> TypeChecker a
getProcMember fn = fn <$> gets tcheckProcDef


-- |Get some attribute of the proc being type checked.
updateProc :: (ProcDef -> ProcDef) -> TypeChecker ()
updateProc fn = modify $ \st -> st { tcheckProcDef = fn $ tcheckProcDef st }


-- |Get some attribute of the proc being type checked.
getTypingMember :: (Typing -> a) -> TypeChecker a
getTypingMember fn = fn <$> gets tcheckTyping


-- |Get whether typing is successful (no errors).
getSuccessful :: TypeChecker Bool
getSuccessful = List.null <$> getTypingMember typingErrs


-- |Get the current determism
getDeterminism :: TypeChecker Determinism
getDeterminism = gets tcheckDetism


-- |Set the current determism
putDeterminism :: Determinism -> TypeChecker ()
putDeterminism detism = do
    st <- get
    put $ st { tcheckDetism = detism }
-- putDeterminism detism = modify $ \st -> st { tcheckDetism = detism }


-- |Execute some code in the context of the specified determinism, leaving
-- the determinism as it is.
withDeterminism :: Determinism -> TypeChecker a -> TypeChecker a
withDeterminism detism checker = do
    olddetism <- getDeterminism
    putDeterminism detism
    result <- checker
    putDeterminism olddetism
    return result


-- |Apply a function to the current typing
modifyTyping :: (Typing -> Typing) -> TypeChecker ()
modifyTyping fn = modify $ \st -> st {tcheckTyping = fn $ tcheckTyping st}


-- |Apply a function to the current type dictionary.
modifyDict :: (Map VarName TypeSpec -> Map VarName TypeSpec) -> TypeChecker ()
modifyDict fn =
    modifyTyping $ \typing -> typing {typingDict = fn $ typingDict typing}


-- |Apply a function to the current type variable dictionary.
modifyTVDict :: (Map TypeVarName TypeSpec -> Map TypeVarName TypeSpec)
             -> TypeChecker ()
modifyTVDict fn =
    modifyTyping $ \typing -> typing {tvarDict = fn $ tvarDict typing}


-- |Record a type error in the TypeChecker monad.
reportTypeError :: TypeError -> TypeChecker ()
reportTypeError = reportTypeErrors . (:[])


-- |Record a list of type errors in the TypeChecker monad.
reportTypeErrors :: [TypeError] -> TypeChecker ()
reportTypeErrors errs = do
    modifyTyping $ \ting -> ting { typingErrs = typingErrs ting ++ errs }
    mapM_ (logTypeCheck . ("Reporting error "++) . show) errs


-- | Record the specified type error if the specified test fails
reportErrorUnless :: TypeError -> Bool -> TypeChecker ()
reportErrorUnless err False = reportTypeError err
reportErrorUnless err True  = return ()


-- |Return the current binding state
getBindingState :: TypeChecker BindingState
getBindingState = gets tcheckBinding


-- |Return the current binding state
putBindingState :: BindingState -> TypeChecker ()
putBindingState bindings = modify $ \st -> st { tcheckBinding = bindings }


-- -- |Get whether a variable is definitely bound
-- getVarBound :: VarName -> TypeChecker Bool
-- getVarBound var = Set.member var <$> gets tcheckBinding


-- |Set a variable to be bound
setVarsBound :: Set VarName -> TypeChecker ()
setVarsBound vars =
    modify $ \st -> st {tcheckBinding = addBindings vars $ tcheckBinding st}


-- |Set that the forward execution cannot reach this point.
setImpossible :: TypeChecker ()
setImpossible = modify $ \st -> st {tcheckBinding = Impossible}


-- |Set that the forward execution cannot reach this point.
setFailing :: TypeChecker ()
setFailing = modify $ \st -> st {tcheckBinding = Failing}


-- -- | Returns the meet of the binding state and the binding state corresponding
-- -- to the specified determinism.
-- meetDeterminism :: Determinism -> BindingState -> BindingState
-- meetDeterminism Det     Impossible     = Impossible
-- meetDeterminism Det     Failing        = Impossible
-- meetDeterminism Det     (Possible set) = Succeeding set
-- meetDeterminism Det     succeeding     = succeeding
-- meetDeterminism SemiDet state          = state


-- | Returns the join of the binding state and the binding state corresponding
-- to the specified determinism.
joinDeterminism :: Determinism -> TypeChecker ()
joinDeterminism Det     = return ()
joinDeterminism SemiDet = do
    st <- getBindingState
    putBindingState $ joinState Failing st


-- |Set that the forward execution cannot reach this point.
setSemiDet :: TypeChecker ()
setSemiDet =
    modify $ \st -> st {tcheckBinding = joinState Failing $ tcheckBinding st}


-- |Return the fully resolved version of a type.
resolveType :: TypeSpec -> TypeChecker TypeSpec
resolveType ty@TypeSpec{}  = fromMaybe InvalidType
                              -- XXX need source position here:
                             <$> lift (lookupType ty Nothing)
resolveType (TypeVar tvar) = lookupTVar tvar
resolveType AnyType        = return AnyType
resolveType InvalidType    = return InvalidType


-- |Lookup the ultimate type of a variable.
lookupVar :: VarName -> TypeChecker TypeSpec
lookupVar var = do
    maybeType  <- gets $ Map.lookup var . typingDict . tcheckTyping
    case maybeType of
      Nothing -> return $ AnyType -- XXX might need to generate a type variable
      Just ty -> do
        ty' <- resolveType ty
        when (ty /= ty') $
            -- implement path compression for faster later variable lookups
            modifyDict $ Map.insert var ty'
        return ty'


-- |Lookup the ultimate binding of a type variable.
lookupTVar :: TypeVarName -> TypeChecker TypeSpec
lookupTVar tvar = do
    maybeType <- gets $ Map.lookup tvar . tvarDict . tcheckTyping
    case maybeType of
      Nothing -> return $ TypeVar tvar
      Just ty -> do
        ty' <- resolveType ty
        when (ty /= ty') $
            -- implement path compression for faster later type variable lookups
            modifyTVDict $ Map.insert tvar ty'
        return ty'


-- |Constrain the type of a program variable, with the specified error applying
-- if the type conflicts with the current typing.  Returns whether successful.
setVarType :: TypeError -> VarName -> TypeSpec -> TypeChecker ()
setVarType err var ty = do
    ty' <- resolveType ty
    setVarTypeR err var ty'


-- |Constrain the type of a program variable, with the specified error applying
-- if the type conflicts with the current typing.  The specified type is trusted
-- to already be fully resolved.
setVarTypeR :: TypeError -> VarName -> TypeSpec -> TypeChecker ()
setVarTypeR err var ty = do
    currType <- lookupVar var
    newType  <- unifyTypesR err currType ty
    logTypeCheck $ "Setting type of variable " ++ var ++ " to " ++ show newType
    if newType == InvalidType
      then reportTypeError err
      else
        when (newType /= currType) $ do
          modifyDict $ Map.insert var newType
          unres  <- getTypingMember unresolved
          unres' <- mapM (resolveVar err var ty) unres
          let (resolved,unres'') =
                List.partition ((<=1) . Set.size . altTypes) unres'
          if any (Set.null . altTypes) resolved
            then reportTypeError err
            else do
              modifyTyping $ \st -> st { unresolved = unres' }
              -- altTypes sets of all Alternatives on resolved are singletons
              let pairs =
                    concatMap
                    (\alt -> zip (altVars alt) (Set.findMin $ altTypes alt))
                    resolved
              mapM_ (uncurry (setVarTypeR err)) pairs



-- |Check through a single Alternatives structure to see if setting the
-- specified variable to the specified type can resolve the choice of proc, in
-- which case, we should set the types of the other arguments as determined by
-- the call.  At least we should narrow the choice if possible.  Update the
-- Alternatives appropriately; return an empty list if it is resolved, or a
-- singleton list otherwise.
resolveVar :: TypeError -> VarName -> TypeSpec -> Alternatives
           -> TypeChecker Alternatives
resolveVar err var ty alt@(Alternatives vars typesSet) = do
    let remains =
          Set.filter (and . zipWith (varTypeCompatible var ty) vars) typesSet
    -- If remains is an empty set, setVarTypeR will report the error
    return $ Alternatives (List.filter (/=var) vars) remains


-- |Is it true that if the variable names are the same, then the types are
-- compatible?
varTypeCompatible :: VarName -> TypeSpec -> VarName -> TypeSpec -> Bool
varTypeCompatible v1 t1 v2 t2 = v1 /= v2 || typeCompatible t1 t2


-- |Is it possible that the two completely resolved types are compatible; ie,
-- passing a value of type t1 to a proc expecting an argument of type t2 could
-- possibly be well typed?  This is similar to unifyTypesR, except that it only
-- checks that the unification could succeed, without actually doing it.
typeCompatible :: TypeSpec -> TypeSpec -> Bool
typeCompatible t1 t2 =
    t1 == t2 -- quickly handle common case
    || case (t1,t2) of
        (InvalidType, _)    -> False
        (_, InvalidType)    -> False
        (AnyType, _)        -> True
        (_, AnyType)        -> True
        (TypeVar _, _)    -> True
        (_, TypeVar _)    -> True
        (TypeSpec m1 n1 p1,
         TypeSpec m2 n2 p2) ->
           n1 == n2 && m1 == m2 && length p1 == length p2
           && and (zipWith typeCompatible p1 p2)


-- |Check that two types are compatible; if not, report the specified error
checkTypeCompatible :: TypeError -> TypeSpec -> TypeSpec -> TypeChecker ()
checkTypeCompatible err t1 t2 = reportErrorUnless err (typeCompatible t1 t2)


-- |Return a type that matches both input TypeSpecs, if possible.  If not,
-- report the specified error.
unifyTypes :: TypeError -> TypeSpec -> TypeSpec -> TypeChecker TypeSpec
unifyTypes err ty1 ty2 = do
    ty1' <- resolveType ty1
    ty2' <- resolveType ty2
    unifyTypesR err ty1' ty2'


-- |Return a type that matches both input TypeSpecs, if possible.  If not,
-- report the specified error.  We assume that the input TypeSpecs have been
-- resolved.
unifyTypesR :: TypeError -> TypeSpec -> TypeSpec -> TypeChecker TypeSpec
unifyTypesR err ty1 ty2 =
    if ty1 == ty2
      then return ty1
      else case (ty1,ty2) of
        (InvalidType, _)    -> return InvalidType
        (_, InvalidType)    -> return InvalidType
        (AnyType, _)        -> return ty2
        (_, AnyType)        -> return ty1
        (TypeVar tv1, _)   -> do
            modifyTVDict $ Map.insert tv1 ty2
            return ty2
        (_, TypeVar tv2)   -> do
            modifyTVDict $ Map.insert tv2 ty1
            return ty1
        (TypeSpec m1 n1 p1,
         TypeSpec m2 n2 p2) ->
          if n1/=n2 || m1/=m2
          then do
              reportTypeError err
              return InvalidType
          else do
              p <- zipWithM (unifyTypes err) p1 p2
              return $ TypeSpec m1 n1 p


-- |The empty typing, with no typing information about any variables or type
-- variables.
initTyping :: Typing
initTyping = Typing Map.empty Map.empty [] []


-- |Does this typing have no type errors?
validTyping :: Typing -> Bool
validTyping Typing{typingErrs=errs} = List.null errs


-- -- |Follow a chain of type references to find the final type.
-- --  This code also sort-circuits all the keys along the path to the
-- --  ultimate reference, where possible, so future lookups will be faster.
-- ultimateRef :: VarName -> Typing -> (VarName,Typing)
-- ultimateRef var typing
--     = let (var',dict') = ultimateRef' var $ typingDict typing
--       in  (var', typing {typingDict = dict' })

-- ultimateRef' :: VarName -> Map VarName TypeSpec
--              -> (VarName,Map VarName TypeSpec)
-- ultimateRef' var dict = (var,dict) -- XXX why bother?
--     -- = case Map.lookup var dict of
--     --       Just (TypeRef v) ->
--     --         let (var',dict') = ultimateRef' v dict
--     --         in (var', Map.insert var (TypeRef var') dict')
--     --       _ -> (var,dict)


-- |Get the type associated with a variable; AnyType if no constraint has
--  been imposed on that variable.
varType :: VarName -> Typing -> TypeSpec
varType var typing = varType' typing $ AnyType -- XXX might need type var


-- |Get the type associated with a variable; AnyType if no constraint has
--  been imposed on that variable.
varType' :: Typing -> TypeSpec -> TypeSpec
varType' _ t@TypeSpec{} = t
varType' _ AnyType      = AnyType
varType' _ InvalidType  = InvalidType
varType' typing (TypeVar tv) =
    maybe AnyType (varType' typing) $ Map.lookup tv $ tvarDict typing


-- |Delay a statement pending the assignment of the specified variables
delayStmt :: Set VarName -> Placed Stmt -> TypeChecker ()
delayStmt vars stmt =
    modify $ \st -> st { tcheckDelayed = (vars,stmt):tcheckDelayed st }


-- | A binding state reflects whether execution will reach a given
-- program point, and if so, whether execution can succeed or fail,
-- and if it can reach there in success, the set of variables that will
-- definitely be defined (bound). These binding states form a lattice, where
-- definitely unreachable is the bottom element, definite success and definite
-- failure are greater, and possible success/possible failure is the top
-- element.  These reflect whether or not success is possible, with the bottom
-- element indicating that neither success nor failure is possible, the top
-- indicating that both are possible, and the other two indicating that exactly
-- one is possible.

data BindingState
    = Impossible               -- ^Execution will neither succeed nor fail
    | Succeeding (Set VarName) -- ^Execution will succeed, binding vars
    | Failing                  -- ^Execution will fail
    | Possible (Set VarName)   -- ^Execution may fail, or succeed binding vars
  deriving (Eq)


instance Show BindingState where
    show Impossible = "impossible"
    show Failing = "failing"
    show (Possible set) =
        "test, binding {" ++ intercalate ", " (Set.toList set) ++ "}"
    show (Succeeding set) =
        "succeeding, binding {" ++ intercalate ", " (Set.toList set) ++ "}"


-- | Is this binding state guaranteed to succeed?
mustSucceed :: BindingState -> Bool
mustSucceed (Succeeding _) = True
mustSucceed _              = False


-- | Is this binding state guaranteed to fail?
mustFail :: BindingState -> Bool
mustFail Failing = True
mustFail _       = False


-- | initial BindingState with nothing bound
initBindingState :: BindingState
initBindingState = Succeeding Set.empty


-- | the join of two BindingStates.
joinState :: BindingState -> BindingState -> BindingState
joinState Impossible state = state
joinState state Impossible = state
joinState Failing (Succeeding vars) = Possible vars
joinState (Succeeding vars) Failing = Possible vars
joinState Failing state = state
joinState state Failing = state
joinState (Succeeding vars1) (Succeeding vars2) =
    Succeeding $ vars1 `Set.intersection` vars2
joinState (Succeeding vars1) (Possible vars2) =
    Possible $ vars1 `Set.intersection` vars2
joinState (Possible vars1) (Succeeding vars2) =
    Possible $ vars1 `Set.intersection` vars2
joinState (Possible vars1) (Possible vars2) =
    Possible $ vars1 `Set.intersection` vars2


-- | the meet of two BindingStates.
meetState :: BindingState -> BindingState -> BindingState
meetState Impossible _ = Impossible
meetState _ Impossible = Impossible
meetState Failing (Succeeding _) = Impossible
meetState (Succeeding _) Failing = Impossible
meetState Failing state = Failing
meetState state Failing = Failing
meetState (Succeeding vars1) (Succeeding vars2) =
    Succeeding $ vars1 `Set.union` vars2
meetState (Succeeding vars1) (Possible vars2) =
    Succeeding $ vars1 `Set.union` vars2
meetState (Possible vars1) (Succeeding vars2) =
    Succeeding $ vars1 `Set.union` vars2
meetState (Possible vars1) (Possible vars2) =
    Possible $ vars1 `Set.union` vars2


-- | Add some bindings to a BindingState
addBindings :: Set VarName -> BindingState -> BindingState
addBindings set Impossible         = Impossible   -- XXX error case?
addBindings set Failing            = Failing         -- XXX error case?
addBindings set1 (Succeeding set2) = Succeeding $ set1 `Set.union` set2
addBindings set1 (Possible set2)   = Possible $ set1 `Set.union` set2


-- -- |Constrain the type of the specified variable to be a subtype of the
-- --  specified type.  If this produces an invalid type, the specified type
-- --  error describes the error.
-- constrainVarType :: TypeError -> VarName -> TypeSpec -> Typing -> Typing
-- constrainVarType reason var ty typing
--     = let (var',typing') = ultimateRef var typing
--       in  case meetTypes ty $ varType var' typing' of
--           InvalidType -> typeError reason typing'
--           newType -> typing {typingDict = Map.insert var' newType
--                                           $ typingDict typing' }


-- -- |Constrain the types of the two specified variables to be identical,
-- --  even following further constraints on the types of either of the vars.
-- unifyVarTypes :: VarName -> VarName -> OptPos -> TypeChecker Bool
-- unifyVarTypes var1 var2 pos = do
--     t1 <- lookupVar var1
--     t2 <- lookupVar var2
--     when t1 /= t2 $  -- nothing to do if they're already equal
--       case (t1, t2) of

--           vLow =  min v1 v2
--           vHigh = max v1 v2
--       in case meetTypes (varType vLow typing2) (varType vHigh typing2) of
--           InvalidType -> typeError
--                          (ReasonEqual (varGet var1) (varGet var2) pos)
--                          typing2
--           newType -> typing2 {typingDict =
--                               Map.insert vLow newType
--                               $ Map.insert vHigh newType
--                               $ typingDict typing2 }



-- typeError :: TypeError -> Typing -> Typing
-- typeError err = typeErrors [err]


-- typeErrors :: [TypeError] -> Typing -> Typing
-- typeErrors newErrs typing =
--     typing {typingErrs = newErrs ++ typingErrs typing}


-- |Returns the first argument restricted to the variables appearing in the
--  second. This must handle cases where variable appearing in chains of
--  indirections (equivalence classes of variables) are projected away.
-- projectTyping :: Typing -> Typing -> Typing
-- projectTyping (Typing typing _ errs) (Typing interest _ _) =
--     -- Typing (Map.filterWithKey (\k _ -> Map.member k interest) typing) errs
--     Typing (projectTypingDict (Map.keys interest) typing Map.empty Map.empty)
--     Map.empty errs


-- -- |Return a map containing the types of the first input map projected onto
-- -- the supplied list of variables (which is in ascending alphabetical
-- -- order) and maintaining the equivalences of the original. The second map
-- -- argument holds the translation from the smallest equivalent variable
-- -- name in the input map to the same for the result.
-- --
-- -- This works by traversing the list of variable names, looking up each in
-- -- the input map.  I
-- projectTypingDict :: [VarName] -> Map VarName TypeRef -> Map VarName TypeRef
--                   -> Map VarName VarName -> Map VarName TypeRef
-- projectTypingDict [] _ result _ = result
-- projectTypingDict (v:vs) dict result renaming
--     = let (v',dict') = ultimateRef' v dict
--           tyspec = varType' v' dict
--       in  case Map.lookup v' renaming of
--               Nothing -> projectTypingDict vs dict
--                          (Map.insert v tyspec result)
--                          (Map.insert v' v renaming)
--               Just v'' -> projectTypingDict vs dict
--                          (Map.insert v (IndirectType v'') result) renaming


----------------------------------------------------------------
--           Type Checking All Procs in a Module
--
-- Because exported procs are required to fully declare their types, type
-- checking/inference can be performed a module at a time, once proc parameter
-- types are checked.  No iteration is necessary to find a fixed point.
----------------------------------------------------------------

-- |Type check a single module. Our type inference is flow sensitive, that is,
-- types flow from callers to callees, but not vice versa. Therefore we analyse
-- bottom-up by intra-module potential call graph SCCs. Type and mode inference
-- are responsible for resolving overloading, which means that the SCCs inferred
-- at this point include all *potential* calls, which are a superset of the
-- actual calls.
typeCheckMod :: ModSpec -> Compiler ()
typeCheckMod thisMod = do
    logTypes $ "**** Type checking module " ++ showModSpec thisMod
    reenterModule thisMod
    procs <- getModuleImplementationField (Map.toList . modProcs)
    let ordered =
            stronglyConnComp
            [(name, name,
              nub $ concatMap (localBodyProcs thisMod . procImpln) procDefs)
             | (name,procDefs) <- procs]
    logTypes $ "**** Strongly connected components:\n" ++
      intercalate "\n"
       (List.map (("    " ++) . intercalate ", " . sccElts) ordered)
    errs <- mapM (typecheckProcSCC thisMod) ordered
    mapM_ (unplacedErr . show) $ concat $ reverse errs
    _ <- reexitModule
    logTypes $ "**** Re-exiting module " ++ showModSpec thisMod


-- |Return a list of the names of all the procs defined in the specified module
-- called by the specified proc.
localBodyProcs :: ModSpec -> ProcImpln -> [Ident]
localBodyProcs thisMod (ProcDefSrc body) =
    foldProcCalls (localCalls thisMod) (++) [] body
localBodyProcs thisMod ProcDefPrim{} =
    shouldnt "Type checking compiled code"

-- |Return a singleton list of the specified proc name if it might live in the
-- specified module, therwise the empty list.
localCalls :: ModSpec -> ModSpec -> Ident -> Maybe Int -> Determinism
           -> Bool -> [Placed Exp] -> [Ident]
localCalls thisMod m name _ _ _ _
  | List.null m || m == thisMod = [name]
localCalls _ _ _ _ _ _ _ = []


----------------------------------------------------------------
--                         Type Checking Procs
----------------------------------------------------------------

-- |Type and mode check one strongly connected component in the local
--  potential call graph of a module. The call graph contains only procs
--  in the one module, because this is being done for type inference,
--  and imported procs must have had their types declared. Returns True
--  if the inferred types are more specific than the old ones and some
--  proc(s) in the SCC depend on procs in the list of mods. In this
--  case, we will have to rerun the typecheck after typechecking the
--  other procs on the list.
typecheckProcSCC :: ModSpec -> SCC ProcName -> Compiler [TypeError]
typecheckProcSCC m (AcyclicSCC name) = do
    -- A single pass is always enough for non-cyclic SCCs
    logTypes $ "**** Type checking non-recursive proc " ++ name
    (_,reasons) <- typecheckProcDecls m name
    return reasons
typecheckProcSCC m (CyclicSCC list) = do
    logTypes $ "**** Type checking recursive procs " ++ intercalate ", " list
    (sccAgain,reasons) <-
        foldM (\(sccAgain,rs) name -> do
                    (sccAgain',reasons) <- typecheckProcDecls m name
                    return (sccAgain || sccAgain', reasons++rs))
        (False, []) list
    if sccAgain
    then typecheckProcSCC m $ CyclicSCC list
    else do
      logTypes $ "**** Completed checking of " ++
             intercalate ", " list ++
             " with " ++ show (length reasons) ++ " errors"
      return reasons


-- |Type and mode check a list of procedure definitions and update the
--  definitions stored in the Compiler monad.  Returns a pair of a Bool,
--  the first saying whether any defnition has been udpated, and the
--  second listing the type errors detected.
typecheckProcDecls :: ModSpec -> ProcName -> Compiler (Bool,[TypeError])
typecheckProcDecls m name = do
    logTypes $ "** Type checking decl of proc " ++ name
    defs <- getModuleImplementationField
            (Map.findWithDefault (error "missing proc definition")
             name . modProcs)
    (sccAgain,revdefs,reasons) <-
        foldM (\(sccAgain,defs,errs) def -> do
                    (again,def',errs') <- typeCheck def typecheckProcDecl
                    return (sccAgain || again,def':defs,errs'++errs))
        (False,[],[]) defs
    updateModImplementation
      (\imp -> imp { modProcs = Map.insert name (reverse revdefs)
                                $ modProcs imp })
    logTypes $ "** New definition of " ++ name ++ ":"
    logTypes $ intercalate "\n" $ List.map (showProcDef 4) (reverse revdefs)
    -- XXX this shouldn't be necessary anymore, but keep it for now for safety
    unless (sccAgain || not (List.null reasons)) $
        mapM_ checkProcDefFullytyped revdefs
    return (sccAgain,reasons)


-- |Type check a single procedure definition, including resolving overloaded
-- calls, handling implied modes, and appropriately ordering calls from
-- nested function application.  We search for a valid resolution
-- deterministically if possible.
typecheckProcDecl :: TypeChecker Bool
typecheckProcDecl = do
    name <- getProcMember procName
    proto <-getProcMember procProto
    let params = procProtoParams proto
    let resources = Set.toList $ procProtoResources proto
    (ProcDefSrc body) <- getProcMember procImpln
    pos <- getProcMember procPos
    vis <- getProcMember procVis
    zipWithM_ setupParam params [1..]
    mapM_ setupResource resources
    typing1 <- getTypingMember id
    logTypeCheck $ "** Type checking proc " ++ name ++ ": " ++ show typing1
    logTypeCheck $ "   with resources: " ++ show resources
    typeCheckBody body
    success <- List.null <$> getTypingMember typingErrs
    logTypeCheck $ "** " ++ (if success then "" else "UN")
                   ++ "successfully completed type checking of " ++ name
    -- If code type checked, then not only mode check the body, but also attach
    -- the type to every variable in the body, and then update params to attach
    -- their types.
    body' <- if success
             then modecheckStmts body
             else return body
    params' <- updateParamTypes params
    when (params /= params')
      $ logTypeCheck $ "  params changed: "
                       ++ intercalate ", " (show <$> params')
    let proto' = proto { procProtoParams = params' }
    updateProc $ \pdef -> pdef { procImpln = ProcDefSrc body'
                               , procProto = proto' }
    when (vis == Public && any ((==AnyType) . paramType) params)
          $ reportTypeError $ ReasonUndeclared name proto' pos
    return $ params /= params'


-- |Record the types and binding state of the specified parameter with
-- its specified argument number in the TypeChecker monad.
setupParam :: Param -> Int -> TypeChecker ()
setupParam (Param name typ flow _) argNum = do
    pos <- getProcMember procPos
    typ' <- fromMaybe AnyType <$> lift (lookupType typ pos)
    procname <- getProcMember procName
    logTypeCheck $ "    type of '" ++ name ++ "' is " ++ show typ'
    setVarType (ReasonParam procname argNum pos) name typ'
    when (flowsIn flow) $ setVarsBound $ Set.singleton name


-- |Set up the type of a single resource as a local variable.
setupResource :: ResourceFlowSpec -> TypeChecker ()
setupResource (ResourceFlowSpec rspec flow) = do
    let resname = resourceName rspec
    pos <- getProcMember procPos
    procname <- getProcMember procName
    mbSpecIface <- lift $ lookupResource rspec pos
    let err = ReasonResource procname resname pos
    case mbSpecIface of
      Nothing -> reportTypeError err
      Just (_,iface) -> do
        mapM_ (uncurry (setVarType err) . mapFst resourceName)
          $ Map.assocs iface
        when (flowsIn flow)
          $ mapM_ (setVarsBound . Set.singleton . resourceName) $ Map.keys iface


-- |Update a list of parameters with their inferred types.
updateParamTypes :: [Param] -> TypeChecker [Param]
updateParamTypes =
    mapM (\p@(Param name _ fl afl) -> do
             ty <- lookupVar name
             return $ Param name ty fl afl)


-- |Type check a list of statements.
typeCheckBody :: [Placed Stmt] -> TypeChecker ()
typeCheckBody = mapM_ (placedApplyM typeCheckStmt)


-- |Typecheck a single statement, without worrying about modes.
typeCheckStmt :: Stmt -> OptPos -> TypeChecker ()
typeCheckStmt (ProcCall m callee procId detism res args) pos =
    typeCheckCall m callee procId detism res args pos
typeCheckStmt (ForeignCall lang instr flags args) pos =
    validateForeign  lang instr flags args pos
typeCheckStmt (TestBool exp) pos        = setExpType ReasonShouldnt exp boolType
typeCheckStmt (And stmts) _             = typeCheckBody stmts
typeCheckStmt (Or stmts) _              = typeCheckBody stmts
typeCheckStmt (Not stmt) _              = placedApplyM typeCheckStmt stmt
typeCheckStmt Nop _                     = return ()
typeCheckStmt stmt@(Cond cond thn els) _ = do
    -- withDeterminism SemiDet $ placedApplyM typeCheckStmt cond
    logTypeCheck $ "Type checking conditional:\n    " ++ showStmt 4 stmt
    withDeterminism SemiDet $ placedApplyM typeCheckStmt cond
    typeCheckBody thn
    typeCheckBody els
typeCheckStmt (Loop nested) _           = typeCheckBody nested
typeCheckStmt (UseResources _ nested) _ = typeCheckBody nested
-- typeCheckStmt (For _ _) = shouldnt "bodyCalls: flattening left For stmt"
typeCheckStmt Break _                   = return ()
typeCheckStmt Next _                    =  return ()



          -- calls' <- zipWith (\(call,detism) typs ->
          --                          StmtTypings call detism typs) procCalls
          --             <$> mapM (callProcInfos . fst) procCalls
          --   let badCalls = List.map typingStmt
          --                  $ List.filter (List.null . typingArgsTypes) calls'
          --   if List.null badCalls
          --     then do
          --       typing <- typecheckCalls m name pos calls' unifTyping [] False

          --       logTypeCheck $ "Typing independent of mode = " ++ show typing
          --       if validTyping typing
          --         then do
          --           logTypeCheck $ "Now mode checking proc " ++ name
          --           let inParams = Set.fromList $ paramName <$>
          --                 List.filter (flowsIn . paramFlow) params
          --           let outParams = Set.fromList $ paramName <$>
          --                 List.filter (flowsOut . paramFlow) params
          --           let inResources =
          --                 Set.map (resourceName . resourceFlowRes)
          --                 $ Set.filter (flowsIn . resourceFlowFlow) resources
          --           let outResources =
          --                 Set.map (resourceName . resourceFlowRes)
          --                 $ Set.filter (flowsIn . resourceFlowFlow) resources
          --           let initialised
          --                      -- XXX should not be necessary
          --                      -- "phantom" is always defined (as nothing)
          --                   = addBindings
          --                     (inParams `Set.union` inResources)
          --                     initBindingState
          --           logTypeCheck $ "Initialised vars: " ++ show initialised
          --           (def',assigned,modeErrs0) <-
          --             modecheckStmts m name pos typing [] initialised detism def
          --           logTypeCheck $ "Vars defined by body: " ++ show assigned
          --           logTypeCheck $ "Output parameters   : "
          --                      ++ intercalate ", " (Set.toList outParams)
          --           logTypeCheck $ "Output resources    : "
          --                      ++ intercalate ", " (Set.toList outResources)
          --           let modeErrs =
          --                 [ReasonResourceUndef name res pos
          --                 | res <- Set.toList
          --                          $ missingBindings outResources assigned]
          --                 ++
          --                 [ReasonOutputUndef name param pos
          --                 | param <- Set.toList
          --                            $ missingBindings outParams assigned]
          --                 ++ modeErrs0
          --           let typing' = typeErrors modeErrs typing
          --           let params' = updateParamTypes typing' params
          --           let proto' = proto { procProtoParams = params' }
          --           let pdef' = pdef { procProto = proto',
          --                              procImpln = ProcDefSrc def' }
          --           -- XXX should just check if params changed
          --           let sccAgain = validTyping typing' && pdef' /= pdef
          --           logTypeCheck $ "===== "
          --                      ++ (if sccAgain then "" else "NO ")
          --                      ++ "Need to check again"
          --                      ++ (if sccAgain then " (if recursive)." else ".")
          --           when sccAgain
          --               (logTypeCheck $ "\n-----------------OLD:"
          --                           ++ showProcDef 4 pdef
          --                           ++ "\n-----------------NEW:"
          --                           ++ showProcDef 4 pdef' ++ "\n")
          --           typing'' <-
          --             foldlM (placedApply1 validateForeign) typing'
          --             (List.filter (isForeign . content) def')
          --           return (pdef',sccAgain,typingErrs typing'')
          --         else
          --           return (pdef,False,typingErrs typing)
          --     else
          --       return (pdef,False,
          --                  List.map (\pcall ->
          --                                case content pcall of
          --                                    ProcCall _ callee _ _ _ _ ->
          --                                        ReasonUndef name callee
          --                                        $ place pcall
          --                                    _ -> shouldnt "typecheckProcDecl")
          --                  badCalls)




----------------------------------------------------------------
--                       Type Checking Wybe Calls
----------------------------------------------------------------

-- |Type check a single Wybe call, including handling overloading.  This finds
-- all the procs the call could possibly name, and filters out the ones that
-- clash with the types already known.  If there are no matching procs, we
-- record a type error.  If there is only one matching proc, then we record the
-- types of all the arguments.
--
-- If there is more than one matching proc, we first find all the argument types
-- that are consistent among all the matching procs and record them.  Then we
-- build a TypeAmbig struct recording the variables and all their possible types
-- and add that to the list of ambiguities.
--
-- Finally, if we have constrained the types of any variables, we go through the
-- list of ambiguities and see if any of them involve a newly constrained
-- variable, in which case we re-filter the possibilities, and if any have been
-- removed, we rescan for any uniquely determined types, install them in the
-- typing, and remove them from the ambiguity list.  If any ambiguity has no
-- remaining possibilities, we record a type error, and if any has become
-- uniquely determined, we remove that ambiguity.
typeCheckCall :: ModSpec -> Ident -> Maybe Int -> Determinism -> Bool
              -> [Placed Exp] -> OptPos -> TypeChecker ()
typeCheckCall m callee procId _ res args pos = do
    -- All calls are assumed Det at this point
    logTypeCheck $ "Type checking call "
                   ++ showStmt 4 (ProcCall m callee procId Det res args)
    procs <- case procId of
      Nothing  -> lift $ callTargets m callee
      Just pid -> return [ProcSpec m callee pid]
    -- XXX probably need to handle test reification and bool testification
    let callArity = length args
    detism <- getDeterminism
    logTypeCheck $ "Call context is " ++ show detism
    paramLists <- lift $ mapM getParams procs
    let arityMatches = List.filter ((== callArity) . length) paramLists
    let paramTypesSet =
          Set.fromList $ List.map (List.map paramType) arityMatches
    logTypeCheck $ "Available argument types : "
                   ++ intercalate "\n                           "
                      (show <$> Set.toList paramTypesSet)
    argTypes <- mapM (placedApply getExpType) args
    logTypeCheck $ "Actual argument types    : "
                   ++ show argTypes
    let consistent = Set.filter
                     (and . zipWith typeCompatible argTypes)
                     paramTypesSet
    logTypeCheck $ "Compatible argument types: "
                   ++ intercalate "\n                          "
                      (show <$> Set.toList consistent)
    caller <- getProcMember procName
    case Set.size consistent of
      0 -> if List.null procs
           then reportTypeError $ ReasonUndef caller callee pos
           else if List.null arityMatches
           -- XXX If detism is SemiDet, then try again for a match with one
           -- extra bool output arg; also if the last call argument is a bool
           -- output and there's a match with a semidet proc with one fewer
           -- argument, then consider it a match.  Use boolFnToTest and
           -- testToBoolFn.
           then reportTypeError
                $ ReasonArity caller callee pos callArity
                  (Set.fromList $ length <$> paramLists)
           else reportTypeError $ ReasonNoMatch caller callee pos
      1 -> do
        let err n = ReasonArgType callee n pos
        zipWith3M_ (setExpType . err) [1..] (content <$> args)
                   $ Set.findMin consistent
      _ -> do  -- Multiple matching calls:  save alternatives and narrow down
        let maybeVarArgs = expVar . content <$> args
        let consistent' =
              Set.map (catMaybes . zipWith ($>) maybeVarArgs) consistent
        let varArgs = catMaybes maybeVarArgs
        let alts = Alternatives varArgs consistent'
        modifyTyping $ \st -> st { unresolved = alts : unresolved st }


-- Monadic version of zipWith3 that ignores the monad payload.  This is defined
-- in MonadUtil, but that's not available in this version of Haskell.
zipWith3M_ :: Monad m => (a -> b -> c -> m d) -> [a] -> [b] -> [c] -> m ()
zipWith3M_ f [] _ _ = return ()
zipWith3M_ f _ [] _ = return ()
zipWith3M_ f _ _ [] = return ()
zipWith3M_ f (a:as) (b:bs) (c:cs) = f a b c >> zipWith3M_ f as bs cs


-- |Return the definite type of Exp.
getExpType :: Exp -> OptPos -> TypeChecker TypeSpec
getExpType IntValue{}     _   = return intType
getExpType FloatValue{}   _   = return floatType
getExpType StringValue{}  _   = return stringType
getExpType CharValue{}    _   = return charType
getExpType (Var name _ _) _   = lookupVar name
getExpType (Typed _ ty _) pos = fromMaybe AnyType <$> lift (lookupType ty pos)
getExpType otherExp       _   =
    shouldnt $ "Invalid expr left after flattening " ++ show otherExp


-- |Update the typing to assign the specified type to the specified expr
setExpType :: TypeError -> Exp -> TypeSpec -> TypeChecker ()
setExpType err (IntValue _) ty     = checkTypeCompatible err ty intType
setExpType err (FloatValue _) ty   = checkTypeCompatible err ty floatType
setExpType err (StringValue _) ty  = checkTypeCompatible err ty stringType
setExpType err (CharValue _) ty    = checkTypeCompatible err ty charType
setExpType err (Var var _ _) ty    = void $ setVarType err var ty
setExpType err (Typed expr ty _) _ = setExpType err expr ty
setExpType err otherExp _          =
    shouldnt $ "Invalid expr left after flattening " ++ show otherExp


expVar :: Exp -> Maybe VarName
expVar (Var var _ _)   = Just var
expVar (Typed exp _ _) = expVar exp
expVar _               = Nothing


-- ----------------------------------------------------------------
-- --                           The Type Lattice
-- ----------------------------------------------------------------

-- Simple strict subtype relation for now; every type is a subtype of the
-- unspecified type, and the invalid type is a subtype of every other type.
-- XXX Extend to support actual subtypes
properSubtypeOf :: TypeSpec -> TypeSpec -> Bool
properSubtypeOf _ AnyType = True
properSubtypeOf InvalidType _ = True
properSubtypeOf (TypeSpec mod1 name1 params1) (TypeSpec mod2 name2 params2) =
    name1 == name2
    && (mod1 == mod2 || List.null mod2)
    && sameLength params1 params2
    && List.all (uncurry subtypeOf) (zip params1 params2)
properSubtypeOf _ _ = False


-- |Non-strict subtype relation
subtypeOf :: TypeSpec -> TypeSpec -> Bool
subtypeOf sub super = sub `properSubtypeOf` super || sub == super


-- |Return the greatest lower bound of two TypeSpecs.
meetTypes :: TypeSpec -> TypeSpec -> TypeSpec
meetTypes ty1 ty2
    | ty1 `subtypeOf` ty2       = ty1
    | ty2 `properSubtypeOf` ty1 = ty2
    | otherwise                 = InvalidType


expType :: Typing -> Placed Exp -> Compiler TypeSpec
expType typing expr = do
    logTypes $ "Finding type of expr " ++ show expr
    ty <- placedApply (expType' typing) expr
    logTypes $ "  Type = " ++ show ty
    return ty


expType' :: Typing -> Exp -> OptPos -> Compiler TypeSpec
expType' _ (IntValue _) _ = return $ TypeSpec ["wybe"] "int" []
expType' _ (FloatValue _) _ = return $ TypeSpec ["wybe"] "float" []
expType' _ (StringValue _) _ = return $ TypeSpec ["wybe"] "string" []
expType' _ (CharValue _) _ = return $ TypeSpec ["wybe"] "char" []
expType' typing (Var name _ _) _ = return $ varType name typing
expType' _ (Typed _ typ _) pos = fromMaybe AnyType <$> lookupType typ pos
expType' _ expr _ =
    shouldnt $ "Expression '" ++ show expr ++ "' left after flattening"


-- |Works out the declared flow direction of an actual parameter, paired
-- with whether or not the actual value is in fact available (is a constant
-- or a previously assigned variable), and with whether the call this arg
-- appears in should be delayed until this argument variable is assigned.
expMode :: Placed Exp -> TypeChecker (FlowDirection,Bool,Maybe VarName)
expMode pexp = do
    assigned <- gets tcheckBinding
    return $ expMode' assigned $ content pexp

expMode' :: BindingState -> Exp -> (FlowDirection,Bool,Maybe VarName)
expMode' _ (IntValue _) = (ParamIn, True, Nothing)
expMode' _ (FloatValue _) = (ParamIn, True, Nothing)
expMode' _ (StringValue _) = (ParamIn, True, Nothing)
expMode' _ (CharValue _) = (ParamIn, True, Nothing)
expMode' assigned (Var name FlowUnknown _)
    = if name `assignedIn` assigned
      then (ParamIn, True, Nothing)
      else (FlowUnknown, False, Just name)
expMode' assigned (Var name flow _) =
    (flow, name `assignedIn` assigned, Nothing)
expMode' assigned (Typed expr _ _) = expMode' assigned expr
expMode' _ expr =
    shouldnt $ "Expression '" ++ show expr ++ "' left after flattening"


-- -- |Update the typing to assign the specified type to the specified expr
-- setExpType :: Exp -> OptPos -> TypeSpec -> Int -> ProcName -> Typing -> Typing
-- setExpType (IntValue _) _ _ _ _ typing = typing
-- setExpType (FloatValue _) _ _ _ _ typing = typing
-- setExpType (StringValue _) _ _ _ _ typing = typing
-- setExpType (CharValue _) _ _ _ _ typing = typing
-- setExpType (Var var _ _) pos typ argnum procName typing
--     = constrainVarType (ReasonArgType procName argnum pos) var typ typing
-- setExpType (Typed expr _ _) pos typ argnum procName typing
--     = setExpType expr pos typ argnum procName typing
-- setExpType otherExp _ _ _ _ _
--     = shouldnt $ "Invalid expr left after flattening " ++ show otherExp


----------------------------------------------------------------
--                       Resolving types and modes
--
-- This code resolves types and modes, including resolving overloaded
-- calls, handling implied modes, and appropriately ordering calls from
-- nested function application (which was not resolved during flattening).
-- We search for a valid resolution deterministically if possible.
--
-- To do this we first collect a list of all the calls in the proc body.
-- We process this maintaining 3 data structures:
--    * a typing:  a map from variable name to type;
--    * a resolution:  a mapping from original call to the selected proc spec;
--    * residue:  a list of unprocessed (delayed) calls with the list of
--      resolutions for each.
--
-- For each call, we collect the list of all possible resolutions, and
-- filter this down to the ones that match the argument types given the
-- current typing. If this is unique, we add it to the resolution mapping
-- and update the typing. If there are no matches, we check if there is a
-- unique resolution taking implied modes into account, and if so we select
-- it. If there are no resolutions at all, even allowing for implied modes,
-- then we can report a type error. If there are multiple matches, we add
-- this call to the residue and move on to the the call.
--
-- This process is repeated using the residue of the previous pass as the
-- input to the next one, repeating as long as the residue gets strictly
-- smaller.  Once it stops getting smaller, we select the remaining call
-- with the fewest resolutions and try selecting each resolution and then
-- processing the remainder of the residue with that "guess".  If only one
-- of the guesses leads to a valid typing, that is the correct typing;
-- otherwise we report a type error.


-- |An individual proc, its formal parameter types and modes, and determinism
data ProcInfo = ProcInfo {
  procInfoProc  :: ProcSpec,
  procInfoArgs  :: [TypeFlow],
  procInfoDetism:: Determinism,
  procInfoInRes :: Set ResourceName,
  procInfoOutRes:: Set ResourceName
  } deriving (Eq,Show)


procInfoTypes :: ProcInfo -> [TypeSpec]
procInfoTypes call = typeFlowType <$> procInfoArgs call


-- |Check if ProcInfo is for a proc with a single Bool output as last arg,
--  and if so, return Just the ProcInfo for the equivalent test proc
boolFnToTest :: ProcInfo -> Maybe ProcInfo
boolFnToTest ProcInfo{procInfoDetism=SemiDet} = Nothing
boolFnToTest pinfo@ProcInfo{procInfoDetism=Det, procInfoArgs=args}
    | List.null args = Nothing
    | last args == TypeFlow boolType ParamOut =
        Just $ pinfo {procInfoArgs=init args, procInfoDetism=SemiDet}
    | otherwise = Nothing


-- |Check if ProcInfo is for a test proc, and if so, return a ProcInfo for
--  the Det proc with a singl Bool output as last arg
testToBoolFn :: ProcInfo -> Maybe ProcInfo
testToBoolFn ProcInfo{procInfoDetism=Det} = Nothing
testToBoolFn pinfo@ProcInfo{procInfoDetism=SemiDet, procInfoArgs=args}
    = Just $ pinfo {procInfoDetism=Det
                   ,procInfoArgs=args ++ [TypeFlow boolType ParamOut]}


-- -- |A single call statement together with the determinism context in which
-- --  the call appears and a list of all the possible different parameter
-- --  list types (a list of types). This type is used to narrow down the
-- --  possible call typings.
-- data StmtTypings = StmtTypings {typingStmt::Placed Stmt,
--                                 typingDetism::Determinism,
--                                 typingArgsTypes::[ProcInfo]}
--     deriving (Eq,Show)


-- -- |Return a list of the proc and foreign calls recursively in a list of
-- --  statements, paired with all the possible resolutions.
-- bodyCalls :: [Placed Stmt] -> Determinism
--           -> TypeChecker [(Placed Stmt, Determinism)]
-- bodyCalls [] _ = return []
-- bodyCalls (pstmt:pstmts) detism = do
--     rest <- bodyCalls pstmts detism
--     let stmt = content pstmt
--     let pos  = place pstmt
--     case stmt of
--         ProcCall{}    -> return $  (pstmt,detism):rest
--         ForeignCall{} -> return $ (pstmt,detism):rest
--         TestBool _    -> return rest
--         And stmts     -> (++rest) <$> bodyCalls stmts detism
--         Or stmts      -> (++rest) <$> bodyCalls stmts detism
--         Not stmt      -> (++rest) <$> bodyCalls [stmt] detism
--         Nop           -> return rest
--         Cond cond thn els -> do
--           cond' <- bodyCalls [cond] SemiDet
--           thn' <- bodyCalls thn detism
--           els' <- bodyCalls els detism
--           return $ cond' ++ thn' ++ els' ++ rest
--         Loop nested   -> (++rest) <$> bodyCalls nested detism
--         UseResources _ nested -> (++rest) <$> bodyCalls nested detism
--         -- For _ _ -> shouldnt "bodyCalls: flattening left For stmt"
--         Break         -> return rest
--         Next          ->  return rest


-- -- |Ensure the two exprs have the same types; if both are variables, this
-- --  means unifying their types.
-- unifyExprTypes :: OptPos -> Placed Exp -> Placed Exp -> TypeChecker ()
-- unifyExprTypes pos a1 a2 = do
--     let args = [a1,a2]
--     let call = ForeignCall "llvm" "move" [] args
--     logTypeCheck $ "Type checking instruction unifying argument types "
--                ++ show a1 ++ " and " ++ show a2
--     let a1Content = content a1
--     let a2Content = content a2
--     noteOutputCast a1Content
--     noteOutputCast a2Content
--     case expVar' a2Content of
--         -- XXX Need new error for move to non-variable
--         Nothing -> reportTypeError
--                    (shouldnt $ "move to non-variable" ++ show call)
--         Just toVar ->
--           case ultimateExp a1Content of
--               Var fromVar _ _ -> do
-- XXX monadise from here.
--                 let typing'' = unifyVarTypes fromVar toVar pos typing'
--                 logTypes $ "Resulting typing = " ++ show typing''
--                 return typing''
--               _ -> do
--                 ty <- expType typing' (Unplaced a1Content)
--                 logTypes $ "constraining var " ++ show toVar
--                            ++ " to type " ++ show ty
--                 return $ constrainVarType
--                          (shouldnt $ "type error in move: " ++ show call)
--                          toVar ty typing'


-- noteOutputCast :: Exp -> Typing -> Typing
-- noteOutputCast (Typed (Var name flow _) typ True) typing
--   | flowsOut flow = constrainVarType ReasonShouldnt name typ typing
-- noteOutputCast _ typing = typing



-- -- |The statement is a ProcCall
-- isRealProcCall :: Stmt -> Bool
-- isRealProcCall ProcCall{} = True
-- isRealProcCall _ = False


-- -- |The statement is a ForeignCall
-- isForeign :: Stmt -> Bool
-- isForeign ForeignCall{} = True
-- isForeign _ = False


-- foreignTypeEquivs :: Stmt -> [(Placed Exp,Placed Exp)]
-- foreignTypeEquivs (ForeignCall "llvm" "move" _ [v1,v2]) = [(v1,v2)]
-- foreignTypeEquivs (ForeignCall "lpvm" "mutate" _ [v1,v2,_,_,_,_,_]) = [(v1,v2)]
-- foreignTypeEquivs _ = []


-- |Get matching ProcInfos for the supplied statement (which must be a call)
callProcInfos :: Placed Stmt -> TypeChecker [ProcInfo]
callProcInfos pstmt =
    case content pstmt of
        ProcCall m name procId _ _ _ -> do
          procs <- case procId of
              Nothing   -> lift $ callTargets m name
              Just pid -> return [ProcSpec m name pid]
          defs <- lift $ mapM getProcDef procs
          return [ ProcInfo proc typflow detism inResources outResources
                 | (proc,def) <- zip procs defs
                 , let params = procProtoParams $ procProto def
                 , let (resourceParams,realParams) =
                         List.partition resourceParam params
                 , let typflow = paramTypeFlow <$> realParams
                 , let inResources =
                         Set.fromList $ paramName <$>
                         List.filter (flowsIn . paramFlow) resourceParams
                 , let outResources =
                         Set.fromList $ paramName <$>
                         List.filter (flowsOut . paramFlow) resourceParams
                 , let detism = procDetism def
                 ]
        stmt ->
          shouldnt $ "callProcInfos with non-call statement "
                     ++ showStmt 4 stmt


-- -- |Return the variable name of the supplied expr.  In this context,
-- --  the expr will always be a variable.
-- expVar :: Exp -> VarName
-- expVar expr = fromMaybe
--               (shouldnt $ "expVar of non-variable expr " ++ show expr)
--               $ expVar' expr


-- -- |Return the variable name of the supplied expr, if there is one.
-- expVar' :: Exp -> Maybe VarName
-- expVar' (Typed expr _ _) = expVar' expr
-- expVar' (Var name _ _) = Just name
-- expVar' _expr = Nothing


-- -- |Return the "primitive" expr of the specified expr.  This unwraps Typed
-- --  wrappers, giving the internal exp.
-- ultimateExp :: Exp -> Exp
-- ultimateExp (Typed expr _ _) = ultimateExp expr
-- ultimateExp expr = expr


-- -- |Type check a list of statement typings, resulting in a typing of all
-- --  variables.  Input is a list of statement typings plus a variable typing,
-- --  output is a final variable typing.  We thread through a residue
-- --  list of unresolved statement typings; when we reach the end of the
-- --  main list of statement typings, we reprocess the residue, providing
-- --  the last pass has resolved some statements.  Thus we make multiple
-- --  passes over the list of statement typings until it is empty.
-- --
-- --  If we complete a pass over the list without resolving any statements
-- --  and a residue remains, then we pick a statement with the fewest remaining
-- --  types and try all the types in turn.  If exactly one of these leads to
-- --  a valid typing, this is the correct one; otherwise it is a type error.
-- --
-- --  To handle a single call, we find the types of all arguments as determined
-- --  by the current typing, and match this list against each of the candidate
-- --  statement typings, filtering out invalid possibilities.  If a single
-- --  possibility remains, we commit to this.  If multiple possibilities remain,
-- --  we keep all of them as a residue and continue with other statements.  If
-- --  no possibilities remain, we determine that the statement typing is
-- --  inconsistent with the initial variable typing (a type error).
-- typecheckCalls :: ModSpec -> ProcName -> OptPos -> [StmtTypings]
--     -> Typing -> [StmtTypings] -> Bool -> Compiler Typing
-- typecheckCalls m name pos [] typing [] _ = return typing
-- typecheckCalls m name pos [] typing residue True =
--     typecheckCalls m name pos residue typing [] False
-- typecheckCalls m name pos [] typing residue False =
--     -- XXX Propagation alone is not always enough to determine a unique type.
--     -- Need code to try to find a mode by picking a residual call with the
--     -- fewest possibilities and try all combinations to see if exactly one
--     -- of them gives us a valid typing.  If not, it's a type error.
--     return $ typeErrors (List.map overloadErr residue) typing
-- typecheckCalls m name pos (stmtTyping@(StmtTypings pstmt detism typs):calls)
--         typing residue chg = do
--     logTypes $ "Type checking call " ++ show pstmt
--     logTypes $ "Calling context is " ++ show detism
--     logTypes $ "Candidate types: " ++ show typs
--     -- XXX Must handle reification of test as a bool
--     let (callee,pexps) = case content pstmt of
--                              ProcCall _ callee' _ _ _ pexps' -> (callee',pexps')
--                              noncall -> shouldnt
--                                         $ "typecheckCalls with non-call stmt"
--                                           ++ show noncall
--     actualTypes <- mapM (expType typing) pexps
--     logTypes $ "Actual arg types: " ++ show actualTypes
--     let matches = List.map
--                   (matchTypeList name callee (place pstmt) actualTypes detism)
--                   typs
--     let validMatches = catOKs matches
--     let validTypes = nub $ procInfoTypes <$> validMatches
--     logTypes $ "Valid arg types = " ++ show validTypes
--     logTypes $ "Converted types = " ++ show (boolFnToTest <$> typs)
--     case validTypes of
--         [] -> do
--           logTypes "Type error: no valid types for call"
--           return $ typeErrors (concatMap errList matches) typing
--         [match] -> do
--           let typing' = List.foldr
--                         (\ (pexp,ty,argnum) ->
--                            placedApply setExpType pexp ty argnum name)
--                         typing
--                         $ zip3 pexps match [1..]
--           logTypes $ "Resulting typing = " ++ show typing'
--           typecheckCalls m name pos calls typing' residue True
--         _ -> do
--           let stmtTyping' = stmtTyping {typingArgsTypes = validMatches}
--           typecheckCalls m name pos calls typing (stmtTyping':residue)
--               $ chg || validMatches /= typs


-- |Match up the argument types of a call with the parameter types of the
-- callee, producing a list of the actual types.  If this list contains
-- InvalidType, then the call would be a type error.
matchTypeList :: Ident -> Ident -> OptPos -> [TypeSpec] -> Determinism
              -> ProcInfo -> MaybeErr ProcInfo
matchTypeList caller callee pos callArgTypes detismContext calleeInfo
    | sameLength callArgTypes args
    = matchTypeList' callee pos callArgTypes calleeInfo
    -- Handle case of SemiDet context call to bool function as a proc call
    | detismContext == SemiDet && isJust testInfo
      && sameLength callArgTypes (procInfoArgs calleeInfo')
    = matchTypeList' callee pos callArgTypes calleeInfo'
    -- Handle case of reified test call
    | isJust detCallInfo
      && sameLength callArgTypes (procInfoArgs calleeInfo'')
    = matchTypeList' callee pos callArgTypes calleeInfo''
    | otherwise
    = Err [ReasonArity caller callee pos (length callArgTypes)
           (Set.singleton $ length args)]
    where args = procInfoArgs calleeInfo
          testInfo = boolFnToTest calleeInfo
          calleeInfo' = fromJust testInfo
          detCallInfo = testToBoolFn calleeInfo
          calleeInfo'' = fromJust detCallInfo

matchTypeList' :: Ident -> OptPos -> [TypeSpec] -> ProcInfo -> MaybeErr ProcInfo
matchTypeList' callee pos callArgTypes calleeInfo =
    if List.null mismatches
    then OK $ calleeInfo
         {procInfoArgs = List.zipWith TypeFlow matches calleeFlows}
    else Err [ReasonArgType callee n pos | n <- mismatches]
    where args = procInfoArgs calleeInfo
          calleeTypes = typeFlowType <$> args
          calleeFlows = typeFlowMode <$> args
          matches = List.zipWith meetTypes callArgTypes calleeTypes
          mismatches = List.map fst $ List.filter ((==InvalidType) . snd)
                       $ zip [1..] matches


----------------------------------------------------------------
--                            Mode Checking
--
-- Mode and determinism checking runs after type checking is completed,
-- attaching types to all variables and reordering statements as necessary.
-- Mode checking must run separately from type checking, because the types of
-- variables may not be determined at their first appearance, but the
----------------------------------------------------------------

-- | which of a set of expected bindings is unbound?
missingBindings :: Set VarName -> BindingState -> Set VarName
missingBindings _ Impossible = Set.empty
missingBindings _ Failing = Set.empty
missingBindings set1 (Possible set2) = set1 Set.\\ set2
missingBindings set1 (Succeeding set2) = set1 Set.\\ set2


-- | Is the specified variable defined in the specified binding state?
assignedIn :: VarName -> BindingState -> Bool
assignedIn _ Impossible         = True
assignedIn _ Failing            = True
assignedIn var (Succeeding set) = var `elem` set
assignedIn var (Possible set)   = var `elem` set


-- |Match up the argument modes of a call with the available parameter
-- modes of the callee.  Determine if all actual arguments are instantiated
-- if the corresponding parameter is an input.
matchModeList :: [(FlowDirection,Bool,Maybe VarName)]
              -> ProcInfo -> Bool
matchModeList modes ProcInfo{procInfoArgs=typModes}
    -- Check that no param is in where actual is out
    = (ParamIn,ParamOut) `notElem` argModes
    where argModes = zip (typeFlowMode <$> typModes) (sel1 <$> modes)


-- |Match up the argument modes of a call with the available parameter
-- modes of the callee.  Determine if the call mode exactly matches the
-- proc mode, treating a FlowUnknown argument as ParamOut.
exactModeMatch :: [(FlowDirection,Bool,Maybe VarName)]
               -> ProcInfo -> Bool
exactModeMatch modes ProcInfo{procInfoArgs=typModes}
    = all (\(formal,actual) -> formal == actual
                               || formal == ParamOut && actual == FlowUnknown)
      $ zip (typeFlowMode <$> typModes) (sel1 <$> modes)


-- |Match up the argument modes of a call with the available parameter
-- modes of the callee.  Determine if the call mode exactly matches the
-- proc mode, treating a FlowUnknown argument as ParamOut.
delayModeMatch :: [(FlowDirection,Bool,Maybe VarName)]
               -> ProcInfo -> Bool
delayModeMatch modes ProcInfo{procInfoArgs=typModes}
    = all (\(formal,actual) -> formal == actual
                               || actual == FlowUnknown
                               && (formal == ParamIn || formal == ParamOut))
      $ zip (typeFlowMode <$> typModes) (sel1 <$> modes)


-- overloadErr :: StmtTypings -> TypeError
-- overloadErr StmtTypings{typingStmt=call,typingArgsTypes=candidates} =
--     -- XXX Need to give list of matching procs
--     ReasonOverload (procInfoProc <$> candidates) $ place call


-- |Given a variable type assignment, resolve modes in a proc body,
--  building a revised, properly moded body, or indicate a mode error.
--  This must handle several cases:
--  * Flow direction for function calls are unspecified; they must be assigned,
--    and may need to be delayed if the use appears before the definition.
--  * Test statements must be handled, determining which stmts in a test
--    context are actually tests, and reporting an error for tests outside
--    a test context
--  * Implied modes:  in a test context, allow in mode where out mode is
--    expected by assigning a fresh temp variable and generating an =
--    test of the variable against the in value.
--  * Handle in-out call mode where an out-only argument is expected.
--  This code threads a set of assigned variables through, which starts as
--  the set of in parameter names.  It also threads through a list of
--  statements postponed because an unknown flow variable is not assigned yet.
modecheckStmts :: [Placed Stmt] -> TypeChecker [Placed Stmt]
modecheckStmts [] = do
    delayed <- gets tcheckDelayed
    if List.null delayed
      then return []
      else shouldnt $ "modecheckStmts reached end of body with delayed stmts:\n"
                      ++ show delayed
modecheckStmts (pstmt:pstmts) = do
    logTypeCheck $ "Mode check stmt " ++ showStmt 16 (content pstmt)
    pstmt' <- placedApplyM modecheckStmt pstmt
    errs <- getTypingMember typingErrs
    assigned <- gets tcheckBinding
    delayed <- gets tcheckDelayed
    logTypeCheck $ "New errors   = " ++ show errs
    logTypeCheck $ "Now assigned = " ++ show assigned
    logTypeCheck $ "Now delayed  = " ++ show delayed
    let (doNow,delayed')
            = List.partition
              (Set.null . (`missingBindings` assigned) . fst)
              delayed
    modify $ \st -> st { tcheckDelayed = delayed'}
    pstmts' <- modecheckStmts $ (snd <$> doNow) ++ pstmts
    return $ pstmt' ++ pstmts'


-- |Mode check a single statement, returning a list of moded statements.  In
-- some cases, statements will need to be delayed until their inputs are bound,
-- in which case the list of statements will be empty, and in other cases a
-- statement will bind variables, allowing delayed statements to be scheduled,
-- in which case the list will contain more than one statement.
--
--  We select a mode as follows:
--    0.  If some input arguments are not assigned, report an uninitialised
--        variable error.
--    1.  If there is an exact match for the current instantiation state
--        (treating any FlowUnknown args as ParamIn), select it.
--    2.  If this is a test context and there is a match for the current
--        instantiation state (treating any FlowUnknown args as ParamIn
--        and allowing ParamIn arguments where the parameter is ParamOut),
--        select it, and transform by replacing each non-identical flow
--        ParamIn argument with a fresh ParamOut variable, and adding a
--        = test call to test the fresh variable against the actual ParamIn
--        argument.
--    3.  If there is a match (possibly with some ParamIn args where
--        ParamOut is expected) treating any FlowUnknown args as ParamOut,
--        then select that mode but delay the call.
--    4.  Otherwise report a mode error.
--
--    In case there are multiple modes that match one of those criteria,
--    select the first that matches.
modecheckStmt :: Stmt -> OptPos -> TypeChecker [Placed Stmt]
modecheckStmt stmt@(ProcCall cmod cname _ _ resourceful args) pos = do
    logTypeCheck $ "Mode checking call   : " ++ show stmt
    assigned <- gets tcheckBinding
    logTypeCheck $ "    with assigned    : " ++ show assigned
    callInfos <- callProcInfos $ maybePlace stmt pos
    actualTypes <- mapM (placedApply getExpType) args
    actualModes <- mapM expMode args
    name <- getProcMember procName
    detism <- getProcMember procDetism
    let flowErrs = [ReasonArgFlow cname num pos
                   | ((mode,avail,_),num) <- zip actualModes [1..]
                   , mode == ParamIn && not avail]
    if not $ List.null flowErrs -- Using undefined var as input?
        then do
            reportTypeErrors flowErrs
            logTypeCheck $ "Unpreventable mode errors: " ++ show flowErrs
            return []
        else do
            let typeMatches
                    = catOKs
                      $ List.map
                        (matchTypeList name cname pos actualTypes detism)
                        callInfos
            -- All the possibly matching modes
            let modeMatches
                    = List.filter (matchModeList actualModes) typeMatches
            logTypeCheck $ "Actual types         : " ++ show actualTypes
            logTypeCheck $ "Actual call modes    : " ++ show actualModes
            logTypeCheck $ "Type-correct modes   : " ++ show typeMatches
            logTypeCheck $ "Possible mode matches: " ++ show modeMatches
            let exactMatches
                    = List.filter (exactModeMatch actualModes) modeMatches
            logTypeCheck $ "Exact mode matches: " ++ show exactMatches
            case exactMatches of
                (match:_) -> do
                  let matchProc = procInfoProc match
                  let matchDetism = procInfoDetism match
                  -- joinDeterminism matchDetism
                  reportTypeErrors
                        -- XXX Should postpone the error until we see if we can
                        -- work out that the test is certain to succeed
                        [ReasonDeterminism (procInfoProc match) matchDetism pos
                        | detism < matchDetism]
                  reportTypeErrors
                        [ReasonResourceUnavail name res pos
                        | res <- Set.toList
                                 $ missingBindings
                                   (procInfoInRes match) assigned
                        ]
                  let args' = List.zipWith setPExpTypeFlow
                              (procInfoArgs match) args
                  let stmt' = ProcCall (procSpecMod matchProc)
                              (procSpecName matchProc)
                              (Just $ procSpecID matchProc)
                              matchDetism resourceful args'
                  setVarsBound $ pexpListOutputs args'
                  setVarsBound $ procInfoOutRes match
                  return [maybePlace stmt' pos]
                [] -> if List.any (delayModeMatch actualModes) modeMatches
                      then do
                        logTypeCheck $ "delaying call: " ++ ": " ++ show stmt
                        let vars = Set.fromList $ catMaybes
                                   $ sel3 <$> actualModes
                        logTypeCheck $ "delaying " ++ showStmt 4 stmt
                        logTypeCheck $ "...pending " ++ show vars
                        delayStmt vars $ maybePlace stmt pos
                        return []
                      else do
                        -- XXX handle implied input mode
                        reportTypeError $ ReasonUndefinedFlow cname pos
                        return []
modecheckStmt stmt@(ForeignCall lang cname flags args) pos = do
    logTypeCheck $ "Mode checking foreign call " ++ show stmt
    assigned <- getBindingState
    logTypeCheck $ "    with assigned " ++ show assigned
    actualTypes <- mapM (placedApply getExpType) args
    actualModes <- mapM expMode args
    let flowErrs = [ReasonArgFlow cname num pos
                   | ((mode,avail,_yy),num) <- zip actualModes [1..]
                   , not avail && mode == ParamIn]
    if not $ List.null flowErrs -- Using undefined var as input?
        then do
            logTypeCheck "delaying foreign call"
            reportTypeErrors flowErrs
            return []
        else do
            let typeflows = List.zipWith TypeFlow actualTypes
                            $ sel1 <$> actualModes
            let args' = List.zipWith setPExpTypeFlow typeflows args
            let stmt' = ForeignCall lang cname flags args'
            let assigned' = pexpListOutputs args'
            logTypeCheck $ "New instr = " ++ show stmt'
            setVarsBound assigned'
            return [maybePlace stmt' pos]
modecheckStmt Nop pos = do
    logTypeCheck $ "Mode checking Nop"
    return [maybePlace Nop pos]
modecheckStmt stmt@(Cond tstStmt thnStmts elsStmts) pos = do
    logTypeCheck $ "Mode checking conditional " ++ show stmt
    assigned  <- getBindingState
    tstStmt'  <- placedApplyM modecheckStmt tstStmt
    assigned1 <- getBindingState
    logTypeCheck $ "Assigned by test: " ++ show assigned1
    -- XXX must use definite version of assigned1 below:
    thnStmts' <- modecheckStmts thnStmts
    assigned2 <- getBindingState
    logTypeCheck $ "Assigned by then branch: " ++ show assigned2
    putBindingState assigned -- Don't assume bindings from test or then branch
    elsStmts' <- modecheckStmts elsStmts
    assigned3 <- getBindingState
    logTypeCheck $ "Assigned by else branch: " ++ show assigned3
    if mustSucceed assigned1 -- is condition guaranteed to succeed?
      then do
        logTypeCheck $ "Assigned by succeeding conditional: " ++ show assigned2
        return $ tstStmt' ++ thnStmts'
      else if mustFail assigned1 -- is condition guaranteed to fail?
      then do
        logTypeCheck $ "Assigned by failing conditional: " ++ show assigned3
        return $ tstStmt' ++ elsStmts'
      else do
        let finalAssigned = assigned2 `joinState` assigned3
        putBindingState finalAssigned
        logTypeCheck $ "Assigned by conditional: " ++ show finalAssigned
        return [maybePlace (Cond (seqToStmt tstStmt') thnStmts' elsStmts') pos]
modecheckStmt stmt@(TestBool exp) pos = do
    logTypeCheck $ "Mode checking test " ++ show exp
    let exp' = [maybePlace
                (TestBool (content
                           $ setPExpTypeFlow (TypeFlow boolType ParamIn)
                             (maybePlace exp pos)))
                 pos]

    case expIsConstant exp of
      Just (IntValue 0) -> do
        setFailing
        return exp'
      Just (IntValue 1) ->
        return [maybePlace Nop pos]
      _ -> do
        setSemiDet
        return exp'
modecheckStmt stmt@(Loop stmts) pos = do
    logTypeCheck $ "Mode checking loop " ++ show stmt
    stmts' <- modecheckStmts stmts
    -- XXX Can only assume vars assigned before first possible loop exit are
    --     actually assigned by loop
    return [maybePlace (Loop stmts') pos]
-- XXX Need to implement these:
modecheckStmt stmt@(UseResources resources stmts) pos = do
    logTypeCheck $ "Mode checking use ... in stmt " ++ show stmt
    stmts' <- modecheckStmts stmts
    return [maybePlace (UseResources resources stmts') pos]
-- XXX Need to implement these:
modecheckStmt stmt@(And stmts) pos = do
    logTypeCheck $ "Mode checking conjunction " ++ show stmt
    stmts' <- modecheckStmts stmts
    return [maybePlace (And stmts') pos]
modecheckStmt stmt@(Or stmts) pos = do
    logTypeCheck $ "Mode checking disjunction " ++ show stmt
    -- XXX must mode check individually and join the resulting states
    stmts' <- modecheckStmts stmts
    return [maybePlace (Or stmts') pos]
modecheckStmt (Not stmt) pos = do
    logTypeCheck $ "Mode checking negation " ++ show stmt
    stmt' <- placedApplyM modecheckStmt stmt
    return [maybePlace (Not (seqToStmt stmt')) pos]
-- modecheckStmt m name defPos typing delayed assigned detism
--     stmt@(For gen stmts) pos = nyi "mode checking For"
modecheckStmt Break pos = do
    setImpossible
    return [maybePlace Break pos]
modecheckStmt Next pos = do
    setImpossible
    return [maybePlace Next pos]


-- selectMode :: [ProcInfo] -> [(FlowDirection,Bool,Maybe VarName)]
--            -> ProcInfo
-- selectMode (procInfo:_) _ = procInfo
-- selectMode _ _ = shouldnt "selectMode with empty list of modes"




-- |Does this parameter correspond to a manifest argument?
resourceParam :: Param -> Bool
resourceParam (Param _ _ _ (Resource _)) = True
resourceParam _ = False


----------------------------------------------------------------
--                    Check foreign calls
----------------------------------------------------------------

-- | Make sure a foreign call is valid; otherwise report an error
validateForeign :: Ident -> Ident -> [Ident] -> [Placed Exp] -> OptPos
                -> TypeChecker ()
validateForeign "llvm" "move" _ [inArg,outArg] pos = do
    logTypeCheck $ "Type checking llvm move ("
                       ++ show inArg ++ ", " ++ show outArg ++ ")"
    inType  <- placedApply getExpType inArg
    outType <- placedApply getExpType outArg
    setExpType (ReasonBadMove inType outType pos) (content outArg) inType
    setExpType (ReasonBadMove inType outType pos) (content inArg) outType
validateForeign lang name tags args pos = do
    argTypes <- mapM (placedApply getExpType) args
    maybeReps <- lift $ mapM lookupTypeRepresentation argTypes
    let numberedMaybes = zip maybeReps [1..]
    let untyped = snd <$> List.filter (isNothing . fst) numberedMaybes
    if List.null untyped
      then do
        let argReps = List.filter (not . repIsPhantom)
                      $ trustFromJust "validateForeign" <$> maybeReps
        logTypeCheck $ "Type checking foreign " ++ lang ++ " call "
                       ++ unwords (name:tags)
                       ++ "(" ++ intercalate ", " (show <$> argReps) ++ ")"
        validateForeignCall lang name tags argReps pos
      else
        reportTypeErrors (flip (ReasonForeignArgType name) pos <$> untyped)


-- | Make sure a foreign call is valid; otherwise report an error
-- XXX Check that the outputs of LLVM instructions are correct, after
--     considering casting.
validateForeignCall :: String -> ProcName -> [String] -> [TypeRepresentation]
                    -> OptPos -> TypeChecker ()
-- just assume C calls are OK
validateForeignCall "c" _ _ _ _ = return ()
-- A move with no non-phantom arguments:  all OK
validateForeignCall "llvm" "move" _ [] pos = return ()
validateForeignCall "llvm" "move" _ [inRep,outRep] pos =
    reportErrorUnless (ReasonWrongOutput "move" outRep inRep pos)
    $ compatibleReps inRep outRep
validateForeignCall "llvm" "move" _ argReps pos =
    reportTypeError $ ReasonForeignArity "move" (length argReps) 2 pos
validateForeignCall "llvm" name flags [inRep1,inRep2,outRep] pos = do
    let opName = unwords $ name:flags
    case Map.lookup opName llvmMapBinop of
      Just (_,fam,outTy) -> do
        reportErrorUnless (ReasonWrongFamily name 1 fam pos)
          $ fam == typeFamily inRep1
        reportErrorUnless (ReasonWrongFamily name 2 fam pos)
          $ fam == typeFamily inRep2
        reportErrorUnless (ReasonIncompatible name inRep1 inRep2 pos)
          $ compatibleReps inRep1 inRep2
      Nothing ->
        if isJust $ Map.lookup opName llvmMapUnop
        then reportTypeError $ ReasonForeignArity name 3 2 pos
        else reportTypeError $ ReasonBadForeign "llvm" name pos
validateForeignCall "llvm" name flags [inRep,outRep] pos = do
    let opName = unwords $ name:flags
    case Map.lookup opName llvmMapUnop of
      Just (_,famIn,famOut) ->
        reportErrorUnless (ReasonWrongFamily name 1 famIn pos)
        $ famIn == typeFamily inRep
      Nothing ->
        if isJust $ Map.lookup opName llvmMapBinop
        then reportTypeError $ ReasonForeignArity name 2 3 pos
        else reportTypeError $ ReasonBadForeign "llvm" name pos
validateForeignCall "llvm" name flags argReps pos = do
    let arity = length argReps
    let opName = intercalate " " (name:flags)
    if isJust $ Map.lookup opName llvmMapBinop
      then reportTypeError $ ReasonForeignArity name arity 3 pos
      else if isJust $ Map.lookup opName llvmMapUnop
      then reportTypeError $ ReasonForeignArity name arity 2 pos
      else reportTypeError $ ReasonBadForeign "llvm" name pos
validateForeignCall "lpvm" name flags argReps pos =
    checkLPVMArgs name flags argReps pos
validateForeignCall lang name flags argReps pos =
    reportTypeError $ ReasonForeignLanguage lang name pos


-- | Are two types compatible for use as inputs to a binary LLVM op?
--   Used for type checking LLVM instructions.
compatibleReps :: TypeRepresentation -> TypeRepresentation -> Bool
compatibleReps Address           Address           = True
compatibleReps Address           (Bits wordSize)   = True
compatibleReps Address           (Signed wordSize) = True
compatibleReps Address           (Floating _)      = False
compatibleReps (Bits wordSize)   Address           = True
compatibleReps (Bits m)          (Bits n)          = m == n
compatibleReps (Bits m)          (Signed n)        = m == n
compatibleReps (Bits _)          (Floating _)      = False
compatibleReps (Signed wordSize) Address           = True
compatibleReps (Signed m)        (Bits n)          = m == n
compatibleReps (Signed m)        (Signed n)        = m == n
compatibleReps (Signed _)        (Floating _)      = False
compatibleReps (Floating _)      Address           = False
compatibleReps (Floating _)      (Bits _)          = False
compatibleReps (Floating _)      (Signed _)        = False
compatibleReps (Floating m)      (Floating n)      = m == n


-- | Check arg types of an LPVM instruction
checkLPVMArgs :: String -> [String] -> [TypeRepresentation] -> OptPos
              -> TypeChecker ()
-- XXX must check arg type representations
checkLPVMArgs "alloc" _ [Bits _,Address] pos = return ()
checkLPVMArgs "alloc" _ [Signed _,Address] pos = return ()
checkLPVMArgs "alloc" _ [sz,struct] pos = do
    reportErrorUnless (ReasonForeignArgRep "alloc" 1 sz "integer" pos)
      $ integerTypeRep sz
    reportErrorUnless (ReasonForeignArgRep "alloc" 2 struct "address" pos)
      $ struct == Address
checkLPVMArgs "alloc" _ args pos =
    reportTypeError $ ReasonForeignArity "alloc" (length args) 2 pos
checkLPVMArgs "access" _ [struct,offset,val] pos = do
    reportErrorUnless (ReasonForeignArgRep "access" 1 struct "address" pos)
      $ struct == Address
    reportErrorUnless (ReasonForeignArgRep "access" 2 offset "integer" pos)
      $ integerTypeRep offset
checkLPVMArgs "access" _ args pos =
    reportTypeError $ ReasonForeignArity "access" (length args) 3 pos
checkLPVMArgs "mutate" _ [old,new,offset,destr,sz,start,val] pos = do
    reportErrorUnless (ReasonForeignArgRep "mutate" 1 old "address" pos)
      $ old == Address
    reportErrorUnless (ReasonForeignArgRep "mutate" 2 new "address" pos)
      $ new == Address
    reportErrorUnless (ReasonForeignArgRep "mutate" 3 offset "integer" pos)
      $ integerTypeRep offset
    reportErrorUnless (ReasonForeignArgRep "mutate" 4 destr "Boolean" pos)
      $ integerTypeRep destr
    reportErrorUnless (ReasonForeignArgRep "mutate" 5 sz "integer" pos)
      $ integerTypeRep sz
    reportErrorUnless (ReasonForeignArgRep "mutate" 6 start "integer" pos)
      $ integerTypeRep start
checkLPVMArgs "mutate" _ args pos =
    reportTypeError $ ReasonForeignArity "mutate" (length args) 7 pos
-- XXX do we still need a cast instruction?
checkLPVMArgs "cast" _ [old,new] pos = return ()
checkLPVMArgs "cast" _ [] pos = return ()
checkLPVMArgs "cast" _ args pos =
    reportTypeError $ ReasonForeignArity "cast" (length args) 2 pos
checkLPVMArgs name _ args pos =
    reportTypeError $ ReasonBadForeign "lpvm" name pos


----------------------------------------------------------------
--                    Check that everything is typed
----------------------------------------------------------------

-- |Sanity check: make sure all args and params of all procs in the
-- current module are fully typed.  If not, report an internal error.
checkFullyTyped :: Compiler ()
checkFullyTyped = do
    procs <- getModuleImplementationField (concat . Map.elems . modProcs)
    mapM_ checkProcDefFullytyped procs


-- |Make sure all args and params in the specified proc def are typed.
checkProcDefFullytyped :: ProcDef -> Compiler ()
checkProcDefFullytyped def = do
    let name = procName def
    let pos = procPos def
    mapM_ (checkParamTyped name pos) $
      zip [1..] $ procProtoParams $ procProto def
    mapM_ (placedApply (checkStmtTyped name pos)) $
          procDefSrc $ procImpln def


procDefSrc :: ProcImpln -> [Placed Stmt]
procDefSrc (ProcDefSrc def) = def
procDefSrc (ProcDefPrim _ _ _) = shouldnt "procDefSrc applied to ProcDefPrim"


checkParamTyped :: ProcName -> OptPos -> (Int,Param) -> Compiler ()
checkParamTyped name pos (num,param) =
    when (AnyType == paramType param) $
      reportUntyped name pos (" parameter " ++ show num)


checkStmtTyped :: ProcName -> OptPos -> Stmt -> OptPos -> Compiler ()
checkStmtTyped name pos (ProcCall pmod pname pid _ _ args) ppos = do
    when (isNothing pid || List.null pmod) $
         shouldnt $ "Call to " ++ pname ++ showMaybeSourcePos ppos ++
                  " left unresolved"
    mapM_ (checkArgTyped name pos pname ppos) $
          zip [1..] $ List.map content args
checkStmtTyped name pos (ForeignCall _ pname _ args) ppos =
    mapM_ (checkArgTyped name pos pname ppos) $
          zip [1..] $ List.map content args
checkStmtTyped _ _ (TestBool _) _ = return ()
checkStmtTyped name pos (And stmts) _ppos =
    mapM_ (placedApply (checkStmtTyped name pos)) stmts
checkStmtTyped name pos (Or stmts) _ppos =
    mapM_ (placedApply (checkStmtTyped name pos)) stmts
checkStmtTyped name pos (Not stmt) _ppos =
    placedApply (checkStmtTyped name pos) stmt
checkStmtTyped name pos (Cond tst thenstmts elsestmts) _ppos = do
    placedApply (checkStmtTyped name pos) tst
    mapM_ (placedApply (checkStmtTyped name pos)) thenstmts
    mapM_ (placedApply (checkStmtTyped name pos)) elsestmts
checkStmtTyped name pos (Loop stmts) _ppos =
    mapM_ (placedApply (checkStmtTyped name pos)) stmts
checkStmtTyped name pos (UseResources _ stmts) _ppos =
    mapM_ (placedApply (checkStmtTyped name pos)) stmts
-- checkStmtTyped name pos (For itr gen) ppos = do
--     checkExpTyped name pos ("for iterator" ++ showMaybeSourcePos ppos) $
--                   content itr
--     checkExpTyped name pos ("for generator" ++ showMaybeSourcePos ppos) $
--                   content itr
checkStmtTyped _ _ Nop _ = return ()
checkStmtTyped _ _ Break _ = return ()
checkStmtTyped _ _ Next _ = return ()


checkArgTyped :: ProcName -> OptPos -> ProcName -> OptPos ->
                 (Int, Exp) -> Compiler ()
checkArgTyped callerName callerPos calleeName callPos (n,arg) =
    checkExpTyped callerName callerPos
                      ("in call to " ++ calleeName ++
                       showMaybeSourcePos callPos ++
                       ", arg " ++ show n) arg


checkExpTyped :: ProcName -> OptPos -> String -> Exp ->
                 Compiler ()
checkExpTyped callerName callerPos msg (Typed expr ty _)
    | ty /= AnyType = checkExpModed callerName callerPos msg expr
checkExpTyped callerName callerPos msg _ =
    reportUntyped callerName callerPos msg


checkExpModed :: ProcName -> OptPos -> String -> Exp
              -> Compiler ()
checkExpModed callerName callerPos msg (Var _ FlowUnknown _)
    = liftIO $ putStrLn $ "Internal error: In " ++ callerName ++
      showMaybeSourcePos callerPos ++ ", " ++ msg ++ " left with FlowUnknown"
checkExpModed _ _ _ _ = return ()



reportUntyped :: ProcName -> OptPos -> String -> Compiler ()
reportUntyped procname pos msg =
    liftIO $ putStrLn $ "Internal error: In " ++ procname ++
      showMaybeSourcePos pos ++ ", " ++ msg ++ " left untyped"


-- |Log a message, if we are logging type checker activity.
logTypes :: String -> Compiler ()
logTypes = logMsg Types


-- |Log a message in the TypeChecker monad, if we are logging type checking.
logTypeCheck :: String -> TypeChecker ()
logTypeCheck = lift . logTypes
