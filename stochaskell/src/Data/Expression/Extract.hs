{-# LANGUAGE MultiWayIf #-}
module Data.Expression.Extract where

import Control.Monad.State
import qualified Data.Array as A
import qualified Data.Array.Abstract as AA
import Data.Expression
import Data.Expression.Const
import Data.List
import Data.List.Extra
import qualified Data.Map.Strict as Map
import Data.Maybe
import Debug.Trace
import Util

substEEnv :: EEnv -> EEnv
substEEnv (EEnv env) = EEnv $ Map.map (substD $ EEnv env) `fixpt` env

subst :: EEnv -> Expression e -> Expression e
subst env = Expression . substD env . erase

substD :: EEnv -> DExpr -> DExpr
substD env e = DExpr $ extractNodeRef simplifyNodeRef simplify env block ret
  where (ret, block) = runDExpr e

reExpr :: EEnv -> Block -> NodeRef -> Expression t
reExpr env block = Expression . reDExpr env block
reDExpr :: EEnv -> Block -> NodeRef -> DExpr
reDExpr env block = DExpr . extractNodeRef simplifyNodeRef simplify env block

extractNodeRef :: (NodeRef -> State Block NodeRef) -> (Node -> State Block NodeRef)
               -> EEnv -> Block -> NodeRef -> State Block NodeRef
extractNodeRef fNodeRef fNode env block = go where
  go r = case r of
    Var i@Internal{} _->
      extractNode $ lookupBlock i block
    Var i t
      | isJust val -> do
        let e = fromJust val
        t' <- typeDExpr e
        if compatible t t' then fromDExpr e else flip trace (fromDExpr e) $ "ERROR "++
         "extractNodeRef: type mismatch "++ show r ++" -> "++ show e ++"; with env:\n"++ show env
      | Volatile{} <- i -> do
        t' <- extractType env block t
        _ <- simplify $ Apply "getExternal" [Var i t'] t'
        return $ Var i t'
      | Dummy{} <- i -> do
        t' <- extractType env block t
        return $ Var i t'
      | Symbol{} <- i -> do
        t' <- extractType env block t
        return $ Var i t'
      where val = lookupEEnv i env
    Const c t -> do
      t' <- extractType env block t
      return $ Const c t'
    Data c i t -> do
      i' <- sequence $ go <$> i
      t' <- extractType env block t
      return $ Data c i' t'
    BlockArray a t -> do
      a' <- sequence $ go <$> a
      t' <- extractType env block t
      fNodeRef $ BlockArray a' t'
    Index v i -> do
      v' <- go v
      i' <- sequence $ go <$> i
      fNodeRef $ Index v' i'
    TagOf d -> do
      d' <- go d
      fNodeRef $ case d' of
        Data k _ _ -> Const (integer k) IntT
        _ -> TagOf d'
    Extract d c i -> do
      d' <- go d
      fNodeRef $ case d' of
        Data k js _ | c == k, i < length js -> js !! i
        _ -> Extract d' c i
    Cond cvs t -> do
      let (cs,vs) = unzip cvs
      cs' <- sequence $ go <$> cs
      vs' <- sequence $ go <$> vs
      t' <- extractType env block t
      fNodeRef $ Cond (zip cs' vs') t'
    Unconstrained t -> do
      t' <- extractType env block t
      return $ Unconstrained t'
    PartiallyConstrained{} -> return r

  extractNode :: Node -> State Block NodeRef
  extractNode n = do
    node <- extractNode' n
    dag <- gets topDAG
    if stickNode dag node then fNode node else liftBlock $ extractNode n

  extractNode' :: Node -> State Block Node
  extractNode' n = case n of
    Apply f args t -> do
      js <- sequence $ go <$> args
      t' <- extractType env block t
      return $ Apply f js t'
    Array sh lam t -> do
      let (lo,hi) = unzip sh
      lo' <- sequence $ go <$> lo
      hi' <- sequence $ go <$> hi
      let sh' = zip lo' hi'
      lam' <- extractLambda lam
      t' <- extractType env block t
      return $ Array sh' lam' t'
    FoldScan fs lr lam sd ls t -> do
      lam' <- extractLambda lam
      sd' <- go sd
      ls' <- go ls
      t' <- extractType env block t
      return $ FoldScan fs lr lam' sd' ls' t'
    Case hd lams t -> do
      hd' <- go hd
      lams' <- sequence $ extractLambda' <$> lams
      t' <- extractType env block t
      return $ Case hd' lams' t'
    Function lam t -> do
      lam' <- extractLambda lam
      t' <- extractType env block t
      return $ Function lam' t'

  extractLambda :: Lambda NodeRef -> State Block (Lambda NodeRef)
  extractLambda (Lambda body hd) = do
    lam <- extractLambda' $ Lambda body [hd]
    let Lambda dag [ret] = lam
    return $ Lambda dag ret

  extractLambda' :: Lambda [NodeRef] -> State Block (Lambda [NodeRef])
  extractLambda' (Lambda body hds) = do
    d <- getNextLevel
    let inps = inputsLevel d body
        ids' = f <$> inps
        env' = bindInputs body ids' `unionEEnv` env
    runLambda inps (sequence $ extractNodeRef fNodeRef fNode env' block' <$> hds)
    where f (i,t) = DExpr . return $ Var i t
          block' = deriveBlock body block

extractType :: EEnv -> Block -> Type -> State Block Type
extractType env block = go where
  go ty = case ty of
    IntT -> return IntT
    RealT -> return RealT
    SubrangeT t a b -> do
      t' <- go t
      a' <- f a
      b' <- f b
      return $ SubrangeT t' a' b'
    ArrayT k sh t -> do
      lo' <- f lo
      hi' <- f hi
      t' <- go t
      return $ ArrayT k (zip lo' hi') t'
      where (lo,hi) = unzip sh
    TupleT ts -> do
      ts' <- sequence $ go <$> ts
      return $ TupleT ts'
    UnionT tss -> do
      tss' <- sequence $ mapM go <$> tss
      return $ UnionT tss'
    RecursiveT -> return RecursiveT
    UnknownType -> return UnknownType
  f :: (Traversable t) => t NodeRef -> State Block (t NodeRef)
  f t = sequence $ extractNodeRef simplifyNodeRef simplify env block <$> t

optimiseE :: Int -> Expression t -> Expression t
optimiseE ol = Expression . optimiseD ol . erase

optimiseD :: Int -> DExpr -> DExpr
optimiseD ol = fixpt f
  where f e = let (ret, block) = runDExpr e in DExpr $
          extractNodeRef (optimiseNodeRef ol) (optimiseNode ol) emptyEEnv block ret

flattenConds :: [(NodeRef,NodeRef)] -> State Block [(NodeRef,NodeRef)]
flattenConds cvs = concat <$> sequence (flattenCond <$> cvs) where
  flattenCond (Cond cas _, b)
    | isConst `all` map snd cas = flattenConds [(c,b) | (c,a) <- cas, getConstVal a == Just 1]
    | otherwise = do
        cs <- sequence [simplifyConj [c,a] | (c,a) <- cas, getConstVal a /= Just 0]
        flattenConds [(c,b) | c <- cs]
  flattenCond (c, Cond cbs_ _) = do
    cbs <- flattenConds cbs_
    case lookup c cbs of
      Just b -> flattenCond (c,b)
      Nothing -> do
        let (cs,vs) = unzip [(simplifyConj [c,c'], b) | (c',b) <- cbs]
        cs' <- sequence cs
        return (zip cs' vs)
  flattenCond cv = return [cv]

optimiseNodeRef :: Int -> NodeRef -> State Block NodeRef
optimiseNodeRef ol (BlockArray a t) = do
  a' <- sequence $ optimiseNodeRef ol <$> a
  optimiseBlockArray ol a' t
optimiseNodeRef ol (Cond cvs t) | isCond `any` (map fst cvs ++ map snd cvs) = do
  cvs' <- flattenConds cvs
  optimiseNodeRef ol $ Cond cvs' t
optimiseNodeRef _ ref = simplifyNodeRef ref

optimiseBlockArray :: Int -> A.Array [Int] NodeRef -> Type -> State Block NodeRef
optimiseBlockArray ol a' t
  | isCond `all` js, replicated (getConds <$> js) =
    let cvs = do
          c <- unreplicate (getConds <$> js)
          let f (Cond cvs' _) = fromJust $ lookup c cvs'
          return (c, BlockArray (f <$> a') t)
    in optimiseNodeRef ol $ Cond cvs t
  | ol >= 2, isCond (head js), getConds (head js) == tailConds = do
    let cs = getConds (head js)
    vs <- sequence $ do
      c <- cs
      let f (Cond cvs' t') = fromMaybe (Unconstrained t') (lookup c cvs')
          f r = r
      return $ optimiseBlockArray ol (f <$> a') t
    optimiseNodeRef ol $ Cond (zip cs vs) t
  | ol >= 2, isBlockMatrix (BlockArray a' t) = blockMatrix' . filter (not . null) $
    filter (not . isUnconstrained) <$> fromBlockMatrix (BlockArray a' t)
  | otherwise = simplifyNodeRef $ BlockArray a' t
  where js = A.elems a'
        tailConds = nub $ sort [c | Cond cvs _ <- tail js, (c,_) <- cvs]

optimiseNode :: Int -> Node -> State Block NodeRef
optimiseNode _ (Apply "<>" [a,b] _) | isBlockMatrix a, isBlockMatrix b = do
  m <- sequence [sequence [blockDot row col | col <- transpose b'] | row <- a']
  blockMatrix' m
  where a' = fromBlockMatrix a
        b' = fromBlockMatrix b
optimiseNode _ (Apply "+" [a,b] _) | isBlockMatrix a, isBlockMatrix b = do
  m <- sequence [sequence [simplify . Apply "+" [x,y] $ typeRef x `coerce` typeRef y
                          | (x,y) <- zip u v] | (u,v) <- zip a' b']
  blockMatrix' m
  where a' = fromBlockMatrix a
        b' = fromBlockMatrix b
optimiseNode _ (Apply "log_det" [i@BlockArray{}] t) = optimiseDet True (fromBlockMatrix i) t
optimiseNode ol (Case (Data c js _) alts _) | Lambda dag [ret] <- alts !! c = do
  block <- get
  let env' = bindInputs dag $ reDExpr emptyEEnv block <$> js
      block' = deriveBlock dag block
  extractNodeRef (optimiseNodeRef ol) (optimiseNode ol) env' block' ret
optimiseNode _ n = simplify n

optimiseDet :: Bool -> [[NodeRef]] -> Type -> State Block NodeRef
optimiseDet lg a t = do
  block <- get
  let isZ (Const c _) = isZeros c
      isZ (Var j@Internal{} _) | Apply "zeros" _ _ <- lookupBlock j block = True
      isZ _ = False
      z = map isZ <$> a
      rotate = optimiseDet lg (tail a ++ [head a]) t
  if | and (tail $ head z), notNull (tail <$> tail a), notNull `all` (tail <$> tail a) -> do
        x <- det' [[head $ head a]]
        y <- det' (tail <$> tail a)
        simplify $ Apply (if lg then "+" else "*") [x,y] t
     | and (head <$> tail z) -> optimiseDet lg (transpose a) t
     | head $ head z, or (not . head <$> tail z) -> rotate
     | or [not (head zrow) && and (tail zrow) | zrow <- z] -> rotate
     | otherwise -> error $ "optimiseDet "++ showBlock' block (show a) ++"\n"++
                            "z = "++ show z
  where det x | isScalarD x = if lg then log x else x
              | lg        = AA.logDet x
              | otherwise = AA.det x
        det' = fromDExpr . det . DExpr . blockMatrix'

extractIndex :: DExpr -> [DExpr] -> DExpr
extractIndex e = DExpr . extractIndexNode emptyEEnv block (lookupBlock r block)
  where (Var r _, block) = runDExpr e

extractIndexNode :: EEnv -> Block -> Node -> [DExpr] -> State Block NodeRef
extractIndexNode env block (Array _ (Lambda body hd) _) idx =
  extractNodeRef simplifyNodeRef simplify env' block' hd
  where env' = bindInputs body idx `unionEEnv` env
        block' = deriveBlock body block
extractIndexNode env block (Apply op [a,b] t) idx
  | op `elem` ["+","-","*","/"] = do
  a' <- extractIndexNodeRef env block a idx
  b' <- extractIndexNodeRef env block b idx
  t' <- extractType env block $ typeIndex (length idx) t
  simplify $ Apply op [a',b'] t'
extractIndexNode env block (Apply "ifThenElse" [c,a,b] t) idx = do
  c' <- extractNodeRef simplifyNodeRef simplify env block c
  a' <- extractIndexNodeRef env block a idx
  b' <- extractIndexNodeRef env block b idx
  t' <- extractType env block $ typeIndex (length idx) t
  simplify $ Apply "ifThenElse" [c',a',b'] t'
extractIndexNode _ _ n idx = error $ "extractIndexNode "++ show n ++" "++ show idx

extractIndexNodeRef :: EEnv -> Block -> NodeRef -> [DExpr] -> State Block NodeRef
extractIndexNodeRef env block r _ | not . isArrayT $ typeRef r =
  extractNodeRef simplifyNodeRef simplify env block r
extractIndexNodeRef env block (Var i@Internal{} _) idx =
  extractIndexNode env block (lookupBlock i block) idx
extractIndexNodeRef _ _ r idx = error $ "extractIndexNodeRef "++ show r ++" "++ show idx

collapseArray :: DExpr -> DExpr
collapseArray e | (ArrayT _ [(lo,hi)] (ArrayT _ [(lo',hi')] t)) <- typeRef ret = DExpr $ do
  los <- sequence $ extractNodeRef simplifyNodeRef simplify emptyEEnv block <$> [lo,lo']
  his <- sequence $ extractNodeRef simplifyNodeRef simplify emptyEEnv block <$> [hi,hi']
  t' <- extractType emptyEEnv block t
  d <- getNextLevel
  let sh = zip los his
      v = (e `extractIndex` [DExpr . return $ Var (Dummy (-1) 1) IntT])
             `extractIndex` [DExpr . return $ Var (Dummy (-1) 2) IntT]
      env' = EEnv $ Map.fromList
        [(LVar (Dummy (-1) 1), DExpr . return $ Var (Dummy d 1) IntT)
        ,(LVar (Dummy (-1) 2), DExpr . return $ Var (Dummy d 2) IntT)]
  lam <- runLambda [(Dummy d 1,IntT),(Dummy d 2,IntT)] (fromDExpr $ substD env' v)
  hashcons $ Array sh lam (ArrayT Nothing sh t')
  where (ret, block) = runDExpr e
collapseArray e = substD emptyEEnv e

constSymbolLike :: (ExprTuple t) => String -> t -> t
constSymbolLike name val = entuple . expr $ do
  t <- extractType emptyEEnv block (typeRef ret)
  return $ Var (Symbol name True) t
  where (ret, block) = runExpr (detuple val)
