{-# LANGUAGE GADTs, ImpredicativeTypes, FlexibleInstances, ScopedTypeVariables,
             FlexibleContexts, TypeFamilies, MultiParamTypeClasses,
             MonadComprehensions, GeneralizedNewtypeDeriving #-}
module Data.Program where

import Prelude hiding (isInfinite)

import Control.Exception
import Control.Monad.Guard
import Control.Monad.State hiding (guard)
import Data.Array.Abstract
import qualified Data.Bimap as Bimap
import Data.Boolean
import Data.Expression hiding (const,foldl,foldr,scanl,scanr)
import qualified Data.Expression as E
import Data.Expression.Const
import Data.Expression.Eval
import Data.List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Monoid
import qualified Data.Number.LogFloat as LF
import Data.Number.Transfinite hiding (log)
import qualified Data.Random as Rand
import Data.Random.Distribution (logPdf)
import Data.Random.Distribution.Abstract
import Data.Set (Set)
import qualified Data.Set as Set
import Debug.Trace
import GHC.Exts hiding ((<#))
import Numeric.SpecFunctions
import Util


------------------------------------------------------------------------------
-- PROGRAMS                                                                 --
------------------------------------------------------------------------------

data PNode = Dist { dName :: String
                  , dArgs :: [NodeRef]
                  , typePNode :: Type
                  }
           | Loop { lShape :: [Interval NodeRef]
                  , lFunc  :: Lambda PNode
                  , typePNode :: Type
                  }
           | HODist { dName :: String
                    , dArg0 :: PNode
                    , dArgs :: [NodeRef]
                    , typePNode :: Type
                    }
           | ITDist { dDefs :: DAG
                    , dBase :: [PNode]
                    , dRets :: [NodeRef]
                    , dInvF :: [DExpr]
                    , dInvJ :: [[DExpr]] -- TODO: just the determinant
                    , typePNode :: Type
                    }
           | Switch { sHead :: NodeRef
                    , sAlts :: [(Lambda NodeRef, [PNode])]
                    , typePNode :: Type
                    }
           deriving (Eq)

dependsPNode :: Block -> PNode -> Set Id
dependsPNode block (Dist _ args _) =
  Set.unions $ map (dependsNodeRef block) args
dependsPNode block (Loop sh (Lambda defs dist) _) =
  Set.unions $ map (d . fst) sh ++ map (d . snd) sh ++ [ddeps]
  where d = dependsNodeRef block
        ddeps = Set.filter ((dagLevel defs >) . idLevel) $
          dependsPNode (deriveBlock defs block) dist

instance Show PNode where
  show (Dist d js t) = unwords (d : map show js) ++" :: P "++ show t
  show (Loop sh (Lambda dag hd) t) = "\n"++
    "  [ "++ (drop 4 . indent . indent $ showLet dag hd) ++"\n"++
    "  | "++ intercalate ", " (zipWith g (inputs dag) sh) ++" ] :: "++ show t
    where g i (a,b) = show i ++" <- "++ show a ++"..."++ show b
  show (ITDist defs base rets invf invj t) = "ITDist"++
    show (defs, reverse base, rets, reverse invf, invj, t)
  show (Switch e alts _) = "switch "++ show e ++" of\n"++ indent cases
    where cases = unlines
            ["C"++ show i ++" "++ intercalate " " (map show $ inputs dag) ++" ->\n"++
              indent (showLet' dag . showPNodes (dagLevel dag) refs $ show ret)
            | (i, (Lambda dag ret, refs)) <- zip [0..] alts]

data PBlock = PBlock { definitions :: Block
                     , actions     :: [PNode]
                     , constraints :: Env
                     }
            deriving (Eq)
emptyPBlock :: PBlock
emptyPBlock = PBlock emptyBlock [] emptyEnv

pnodes :: PBlock -> Map Id PNode
pnodes (PBlock _ refs _) = pnodes' 0 $ reverse refs
pnodes' :: Int -> [PNode] -> Map Id PNode
pnodes' d = Map.fromList . zip (Volatile d <$> [0..])

showPNodes :: Int -> [PNode] -> String -> String
showPNodes d refs ret = "do "++ indent' 0 3 s ++"\n"++
                        "   return "++ ret
  where s = unlines [show i ++" <- "++ show r | (i,r) <- Map.toList $ pnodes' d refs]

-- lift into Block
liftExprBlock :: MonadState PBlock m => State Block b -> m b
liftExprBlock s = do
    PBlock block rhs given <- get
    let (ret, block') = runState s block
    put $ PBlock block' rhs given
    return ret

newtype Prog t = Prog { fromProg :: State PBlock t }
  deriving (Functor,Applicative,Monad)
type P t = Prog t
instance (Eq t) => Eq (Prog t) where p == q = runProg p == runProg q
runProg :: Prog a -> (a, PBlock)
runProg p = runState (fromProg p) emptyPBlock

instance (ExprTuple t) => Show (Prog t) where
  show p = showBlock block . showPNodes 0 (reverse refs) $ show rets
    where (rets, PBlock (Block block) refs _) = runProgExprs p

fromProgExprs :: (ExprTuple t) => Prog t -> State PBlock [NodeRef]
fromProgExprs p = do
  es <- fromExprTuple <$> fromProg p
  mapM (liftExprBlock . fromDExpr) es

runProgExprs :: (ExprTuple t) => Prog t -> ([NodeRef], PBlock)
runProgExprs p = runState (fromProgExprs p) emptyPBlock

-- all samples whose density depends on the value of non-fixed parameters
-- ie. not constant wrt the given data
modelSkeleton :: PBlock -> Set Id
modelSkeleton pb@(PBlock block _ given) = tparams
  where samples = pnodes pb
        params = Map.keysSet samples Set.\\ Map.keysSet given
        dependents xs = Set.union xs . Map.keysSet $
          Map.filter (not . Set.null . Set.intersection xs . dependsPNode block) samples
        dparams = fixpt dependents params
        tparams = Set.foldr Set.union dparams $ Set.map g dparams
        -- TODO: warn when any samples\\tparams have zero density
          where g i = let n = fromJust $ Map.lookup i samples
                      in Set.filter isInternal $ dependsPNode block n

evalProg :: (ExprTuple t) => Env -> Prog t -> Maybe t
evalProg env prog = do
  xs <- sequence (evalNodeRef (Map.union given env) block <$> rets)
  return $ fromConstVals xs
  where (rets, PBlock block _ given) = runProgExprs prog

caseP :: DExpr -> [[DExpr] -> P DExpr] -> P DExpr
caseP e ps = Prog $ do
  k <- liftExprBlock $ fromDExpr e
  case k of
    Data c args _ -> do
      block <- liftExprBlock get
      let p = ps !! c
          args' = reDExpr emptyEEnv block <$> args
      fromProg $ p args'
    _ -> fromProg $ caseP' k ps

caseP' :: NodeRef -> [[DExpr] -> P DExpr] -> P DExpr
caseP' k ps = fmap erase . dist $ do
  d <- getNextLevel
  let UnionT tss = typeRef k
  cases <- sequence $ do
    (ts,p) <- zip tss ps
    let ids = [Dummy d i | i <- [0..(length ts - 1)]]
        args = [DExpr . return $ Var i t | (i,t) <- zip ids ts]
    return $ do
      block <- get
      let s = do
            r <- fromProg $ p args
            liftExprBlock $ fromDExpr r
          (ret, PBlock (Block (dag:block')) acts _) = runState s $
            PBlock (deriveBlock (DAG d ids Bimap.empty) block) [] emptyEnv
      put $ Block block'
      return (Lambda dag ret, reverse acts)
  return $ Switch k cases (unreplicate $ typeRef . fHead . fst <$> cases)


------------------------------------------------------------------------------
-- PRIMITIVE DISTRIBUTIONS                                                  --
------------------------------------------------------------------------------

dist :: State Block PNode -> Prog (Expr t)
dist s = Prog $ do
    d <- liftExprBlock s
    PBlock block rhs given <- get
    put $ PBlock block (d:rhs) given
    let depth = dagLevel $ topDAG block
        k = length rhs
        name = Volatile depth k
        t = typePNode d
        v = Var name t
    _ <- liftExprBlock . simplify $ Apply "getExternal" [v] t
    return (expr $ return v)

truncated :: (Expr t) -> (Expr t) -> P (Expr t) -> P (Expr t)
truncated a b p = Prog $ do
  i <- liftExprBlock $ fromExpr a
  j <- liftExprBlock $ fromExpr b
  x <- fromProg p
  (Var name t) <- liftExprBlock $ fromExpr x
  PBlock block (d:rhs) given <- get
  when (name /= Volatile (dagLevel $ topDAG block) (length rhs)) $
    error "truncated: program does not appear to be primitive"
  let g k | (Const c _) <- k, isInfinite c = Nothing
          | otherwise = Just k
      t' = SubrangeT t (g i) (g j)
      d' = d { typePNode = t' }
  put $ PBlock block (d':rhs) given
  return (expr $ return (Var name t'))

transform :: (ExprTuple t) => Prog t -> Prog t
transform prog = Prog $ do
  (PBlock block acts given) <- get
  assert (given == emptyEnv) $ return ()
  let d = nextLevel block
      dBlock = deriveBlock (DAG d [] Bimap.empty) block
      (rets, PBlock dBlock'@(Block (dag:block')) acts' _) =
        runState (fromProgExprs prog) $ PBlock dBlock [] emptyEnv
      ids = Dummy (d-1) <$> [0..(length rets - 1)]
      zs = zipWith Var ids $ map typeRef rets
      eenv = solveTupleD dBlock' rets (DExpr . return <$> zs) emptyEEnv
      invfs = [fromMaybe (error "not invertible") $ Map.lookup x eenv
              | x <- map (Volatile d) [0..(length acts' - 1)]]
      ts = typeRef <$> rets
      t = if length rets > 1 then TupleT ts else head ts
      jacobian = [[collapseArray $ derivD emptyEEnv u (Var (Dummy 0 j) (ts!!j))
                  | u <- invfs] | j <- [0..(length rets - 1)]]
      pnode = ITDist dag acts' rets (reverse invfs) jacobian t
  put $ PBlock (Block block') (pnode:acts) emptyEnv
  let k = length acts
      name = Volatile (d-1) k
      v = Var name t
  return . toExprTuple . map (DExpr . return) $ if length rets > 1
    then Extract v 0 <$> [0..(length rets - 1)] -- TODO extractD
    else [v]

instance Distribution Bernoulli R Prog B where
    sample (Bernoulli p) = dist $ do
        i <- fromExpr p
        return $ Dist "bernoulli" [i] boolT
    sample (BernoulliLogit l) = dist $ do
        i <- fromExpr l
        return $ Dist "bernoulliLogit" [i] boolT

instance Distribution Bernoullis RVec Prog BVec where
    sample (Bernoullis p) = dist $ do
        i <- fromExpr p
        let (ArrayT _ [n] _) = typeRef i
        return $ Dist "bernoullis" [i] (ArrayT Nothing [n] boolT)
    sample (BernoulliLogits l) = dist $ do
        i <- fromExpr l
        let (ArrayT _ [n] _) = typeRef i
        return $ Dist "bernoulliLogits" [i] (ArrayT Nothing [n] boolT)

instance Distribution Beta (R,R) Prog R where
    sample (Beta (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "beta" [i,j] RealT

instance (ScalarType t) => Distribution Categorical [(R, Expr t)] Prog (Expr t) where
    sample (Categorical pxs) = dist $ do
        let (ps,xs) = unzip pxs
        qs <- mapM fromExpr ps
        ys <- mapM fromExpr xs
        let TypeIs t = typeOf :: TypeOf t
        return $ Dist "categorical" (qs ++ ys) t

instance Distribution Cauchy (R,R) Prog R where
    sample (Cauchy (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "cauchy" [i,j] RealT

instance Distribution Cauchys (RVec,RVec) Prog RVec where
    sample (Cauchys (m,s)) = dist $ do
        i <- fromExpr m
        j <- fromExpr s
        return $ Dist "cauchys" [i,j] (typeRef i)

instance Distribution Gamma (R,R) Prog R where
    sample (Gamma (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "gamma" [i,j] RealT

instance Distribution InvGamma (R,R) Prog R where
    sample (InvGamma (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "inv_gamma" [i,j] RealT

instance Distribution Geometric R Prog Z where
    sample (Geometric p) = dist $ do
        i <- fromExpr p
        return $ Dist "geometric" [i] IntT

instance Distribution LKJ (R, Interval Z) Prog RMat where
    sample (LKJ (v,(a,b))) = dist $ do
        i <- fromExpr v
        l <- fromExpr a
        h <- fromExpr b
        return $ Dist "lkj_corr" [i] (ArrayT (Just "corr_matrix") [(l,h),(l,h)] RealT)

instance Distribution NegBinomial (R,R) Prog Z where
    sample (NegBinomial (r,p)) = dist $ do
        i <- fromExpr r
        j <- fromExpr p
        return $ Dist "neg_binomial" [i,j] IntT

instance Distribution Normal (R,R) Prog R where
    sample (Normal (m,s)) = dist $ do
        i <- fromExpr m
        j <- fromExpr s
        return $ Dist "normal" [i,j] RealT

instance Distribution Normals (RVec,RVec) Prog RVec where
    sample (Normals (m,s)) = dist $ do
        i <- fromExpr m
        j <- fromExpr s
        return $ Dist "normals" [i,j] (typeRef i)

instance Distribution Normals (RMat,RMat) Prog RMat where
    sample (Normals (m,s)) = dist $ do
        i <- fromExpr m
        j <- fromExpr s
        return $ Dist "normals" [i,j] (typeRef i)

instance Distribution Normal (RVec,RMat) Prog RVec where
    sample (Normal (m,s)) = dist $ do
        i <- fromExpr m
        j <- fromExpr s
        return $ Dist "multi_normal" [i,j] (typeRef i)

instance (ScalarType t) => Distribution OrderedSample (Z, Prog (Expr t)) Prog (Expr [t]) where
    sample (OrderedSample (n,prog)) = Prog $ do
        i <- liftExprBlock $ fromExpr n
        PBlock block rhs given <- get
        let (_, PBlock block' [act] _) =
              runState (head <$> fromProgExprs prog) $ PBlock block [] emptyEnv
            d = HODist "orderedSample" act [i] (ArrayT Nothing [(Const 1 IntT,i)] (typePNode act))
        put $ PBlock block' (d:rhs) given
        let depth = dagLevel $ topDAG block
            k = length rhs
            name = Volatile depth k
            t = typePNode d
            v = Var name t
        _ <- liftExprBlock . simplify $ Apply "getExternal" [v] t
        return (expr $ return v)

instance Distribution PMF RVec Prog Z where
    sample (PMF probs) = dist $ do
        l <- fromExpr probs
        return $ Dist "pmf" [l] IntT

instance Distribution Poisson R Prog Z where
    sample (Poisson a) = dist $ do
        i <- fromExpr a
        return $ Dist "poisson" [i] IntT

instance Distribution Uniform (R,R) Prog R where
    sample (Uniform (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "uniform" [i,j] RealT

instance Distribution Uniforms (RVec,RVec) Prog RVec where
    sample (Uniforms (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "uniforms" [i,j] (typeRef i)

instance Distribution Uniforms (RMat,RMat) Prog RMat where
    sample (Uniforms (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "uniforms" [i,j] (typeRef i)

instance Distribution Uniform (Z,Z) Prog Z where
    sample (Uniform (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "discreteUniform" [i,j] IntT

instance Distribution Wishart (R,RMat) Prog RMat where
    sample (Wishart (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "wishart" [i,j] (typeRef j)

instance Distribution InvWishart (R,RMat) Prog RMat where
    sample (InvWishart (a,b)) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        let (ArrayT _ sh t) = typeRef j
        return $ Dist "inv_wishart" [i,j] (ArrayT (Just "cov_matrix") sh t)

normalChol :: Z -> RVec -> RMat -> P RVec
normalChol n mu cov = do
  --w <- joint vector [ normal 0 1 | _ <- 1...n ]
  w <- normals (vector [ 0 | _ <- 1...n ])
               (vector [ 1 | _ <- 1...n ])
  return (mu + chol cov #> w)

normalsChol :: Z -> Z -> RVec -> RMat -> P RMat
normalsChol n k mu cov = do
  --w <- joint vector [ normal 0 1 | i <- 1...n, j <- 1...k ]
  w <- normals (matrix [ 0 | i <- 1...n, j <- 1...k ])
               (matrix [ 1 | i <- 1...n, j <- 1...k ])
  return $ asRow mu + (w <> tr' (chol cov))

normalCond :: Z -> (Expr t -> Expr t -> R) -> Expr [t] -> RVec -> Expr t -> P R
normalCond n cov s y x = normal m (sqrt v)
  where c = matrix [ cov (s!i) (s!j) | i <- 1...n, j <- 1...n ] :: RMat
        k = vector [ cov (s!i) x     | i <- 1...n ] :: RVec
        m = y <.> (inv c #> k)
        v = cov x x - k <.> (inv c #> k)


------------------------------------------------------------------------------
-- LOOPS                                                                    --
------------------------------------------------------------------------------

instance forall r f. ScalarType r =>
         Joint Prog Z (Expr r) (Expr f) where
  joint _ ar = Prog $ do
    sh <- liftExprBlock . sequence . flip map (shape ar) $ \(a,b) -> do
      i <- fromExpr a
      j <- fromExpr b
      return (i,j)
    PBlock block dists given <- get
    let d = nextLevel block
        ids = [ Dummy d i | i <- [1..length sh] ]
        p = ar ! [expr . return $ Var i IntT | i <- ids]
        (ret, PBlock (Block (dag:block')) [act] _) =
          runState (head <$> fromProgExprs p) $
            PBlock (deriveBlock (DAG d ids Bimap.empty) block) [] emptyEnv
        TypeIs t = typeOf :: TypeOf r -- TODO: incorrect type for transformed case
        loopType = ArrayT Nothing sh t
        loop = Loop sh (Lambda dag act) loopType
    put $ PBlock (Block block') (loop:dists) given
    let name = Volatile (d-1) (length dists)
        v = Var name loopType
    _ <- liftExprBlock . simplify $ Apply "getExternal" [v] loopType
    return $ case ret of
      Var (Volatile depth 0) _ | depth == d ->
        expr $ return v :: Expr f
      Index vec [Var (Volatile depth 0) _] | depth == d ->
        expr . floatArray' $ Array sh (Lambda dag (Index vec [ref])) loopType
          where ref = Index v (reverse [Var i IntT | i <- ids])
      _ -> error $ "non-trivial transform in joint: "++ show ret


------------------------------------------------------------------------------
-- CONDITIONING                                                             --
------------------------------------------------------------------------------

type instance ConditionOf (Prog ()) = Expr Bool
instance MonadGuard Prog where
    guard cond = Prog $ do -- TODO: weaker assumptions
        (Var (Internal 0 i) _) <- liftExprBlock (fromExpr cond)
        (PBlock block dists given) <- get
        let dag = topDAG block
        assert (i == length (nodes dag) - 1) $ return ()
        let (Just (Apply "==" [Var j _, Const a _] _)) =
              lookup i $ nodes dag
            dag' = dag { bimap = Bimap.deleteR i (bimap dag) }
        put $ PBlock (deriveBlock dag' block) dists (Map.insert j a given)

dirac :: (Expr t) -> Prog (Expr t)
dirac c = do
  x <- dist $ do
    i <- fromExpr c
    return $ Dist "dirac" [i] (typeRef i)
  guard $ x ==* c
  return x


------------------------------------------------------------------------------
-- PROBABILITY DENSITIES                                                    --
------------------------------------------------------------------------------

pdf :: (ExprTuple t) => Prog t -> t -> R
pdf prog vals = pdfPBlock env pb
  where (rets, pb@(PBlock block _ _)) = runProgExprs prog
        env = solveTupleD block rets (fromExprTuple vals) emptyEEnv

pdfPBlock :: EEnv -> PBlock -> R
pdfPBlock env (PBlock block refs _) = product $ do
    (i,d) <- zip [0..] $ reverse refs
    let ident = Volatile (dagLevel $ topDAG block) i
    return $ case Map.lookup ident env of
      Just val -> pdfPNode env block d val
      Nothing  -> trace (show ident ++" is unconstrained") 1

pdfPNode :: EEnv -> Block -> PNode -> DExpr -> R
pdfPNode env block (Dist f args _) x = expr $ do
  i <- fromDExpr x
  case i of
    Unconstrained _ -> return (Const 1 RealT)
    _ -> do
      js <- sequence $ extractNodeRef env block <$> args
      simplify $ Apply (f ++"_pdf") (i:js) RealT
pdfPNode env block (Loop _ (Lambda ldag body) _) a
  | (Unconstrained _,_) <- runDExpr a = 1
  | otherwise = E.foldl f 1 (Expr a)
  where block' = deriveBlock ldag block
        f p x = p * pdfPNode env block' body (erase x) -- TODO only works for iid

density :: (ExprTuple t) => Prog t -> t -> LF.LogFloat
density prog vals = densityPBlock env' pb / adjust
  where (rets, pb@(PBlock block acts _)) = runProgExprs prog
        env = unifyTuple block rets vals emptyEnv
        env' = evalBlock block env
        jacobian = [ [ diffNodeRef env' block r (Volatile 0 i) (typePNode d)
                     | (i,d) <- zip [0..] (reverse acts), typePNode d /= IntT ]
                   | r <- rets, typeRef r /= IntT ]
        isLowerTri = and [ isZeros `all` drop i row | (i,row) <- zip [1..] jacobian ]
        diagonal = [ row !! i | (i,row) <- zip [0..] jacobian ]
        ldet = LF.logToLogFloat . real . logDet :: ConstVal -> LF.LogFloat
        adjust | isLowerTri = product (map ldet diagonal)
               | otherwise = error "jacobian is not block triangular"

density' :: (ExprTuple t) => Prog t -> t -> LF.LogFloat
density' prog vals = densityPBlock env' pb
  where (rets, pb@(PBlock block _ _)) = runProgExprs prog
        env = unifyTuple block rets vals emptyEnv
        env' = evalBlock block env

densityPBlock :: Env -> PBlock -> LF.LogFloat
densityPBlock env (PBlock block refs _) = product $ do
    (i,d) <- zip [0..] $ reverse refs
    let ident = Volatile (dagLevel $ topDAG block) i
    return $ case Map.lookup ident env of
      Just val -> let p = densityPNode env block d val
        in {-trace ("density ("++ show d ++") "++ show val ++" = "++ show p)-} p
      Nothing  -> trace (show ident ++" is unconstrained") $ LF.logFloat 1

densityPNode :: Env -> Block -> PNode -> ConstVal -> LF.LogFloat
densityPNode env block (Dist "bernoulli" [p] _) x =
    LF.logFloat (if toBool x then p' else 1 - p')
  where p' = toDouble . fromJust $ evalNodeRef env block p
densityPNode env block (Dist "bernoulliLogit" [l] _) a
    | x == 1 = LF.logFloat p
    | x == 0 = LF.logFloat (1 - p)
    | otherwise = LF.logFloat 0
  where x = toRational a
        l' = toDouble . fromJust $ evalNodeRef env block l
        p = 1 / (1 + exp (-l'))
densityPNode env block (Dist "categorical" cats _) x = LF.logFloat $ toDouble p
  where n = length cats `div` 2
        ps = fromJust . evalNodeRef env block <$> take n cats
        xs = fromJust . evalNodeRef env block <$> drop n cats
        p = fromMaybe 0 . lookup x $ zip xs ps
densityPNode env block (Dist "gamma" [a,b] _) x
    | x' >= 0 = LF.logToLogFloat l
    | otherwise = LF.logFloat 0
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
        x' = toDouble x
        l = a' * log b' + (a' - 1) * log x' - b' * x' - logGamma a'
densityPNode env block (Dist "inv_gamma" [a,b] _) x
    | x' >= 0 = LF.logToLogFloat l
    | otherwise = LF.logFloat 0
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
        x' = toDouble x
        l = a' * log b' - (a' + 1) * log x' - b' / x' - logGamma a'
densityPNode env block (Dist "geometric" [t] _) x = p * q^k
  where t' = toDouble . fromJust $ evalNodeRef env block t
        p = LF.logFloat t'
        q = LF.logFloat (1 - t')
        k = toInteger x
densityPNode env block (Dist "normal" [m,s] _) x =
    LF.logToLogFloat $ logPdf (Rand.Normal m' s') (toDouble x)
  where m' = toDouble . fromJust $ evalNodeRef env block m
        s' = toDouble . fromJust $ evalNodeRef env block s
densityPNode env block (Dist "multi_normal" [m,s] _) x =
    LF.logToLogFloat $ -0.5 * (real $ (x' <.> (s' <\> x')) + logDet s' + n * log (2*pi))
  where m' = fromJust $ evalNodeRef env block m
        s' = fromJust $ evalNodeRef env block s
        n = integer $ length (toList m')
        x' = x - m'
densityPNode env block (Dist "poisson" [l] _) x =
    LF.logToLogFloat $ fromIntegral k * log l' - l' - logFactorial k
  where l' = toDouble . fromJust $ evalNodeRef env block l
        k = toInteger x
densityPNode env block (Dist "uniform" [a,b] _) x =
    LF.logFloat $ if a' <= x' && x' <= b' then 1/(b' - a') else 0
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
        x' = toDouble x
densityPNode env block (Dist "discreteUniform" [a,b] _) x =
    LF.logFloat $ if a' <= x' && x' <= b' then 1/(fromInteger $ b' - a' + 1) else 0
  where a' = toInteger . fromJust $ evalNodeRef env block a
        b' = toInteger . fromJust $ evalNodeRef env block b
        x' = toInteger x
densityPNode _ _ (Dist d _ _) _ = error $ "unrecognised density "++ d

densityPNode env block (Loop shp (Lambda ldag body) _) a = product
    [ let p = densityPNode (Map.fromList (zip inps i) `Map.union` env) block' body (fromRational x)
      in {-trace ("density ("++ show body ++") "++ show (fromRational x :: Double) ++" = "++ show p)-} p
    | (i,x) <- evalRange env block shp `zip` entries a ]
  where inps = inputs ldag
        block' = deriveBlock ldag block

densityPNode env block (HODist "orderedSample" d [n] _) a = lfact n' * product
    [ densityPNode env block d (fromRational x) | x <- entries a ]
  where n' = toInteger . fromJust $ evalNodeRef env block n


------------------------------------------------------------------------------
-- SAMPLING                                                                 --
------------------------------------------------------------------------------

simulate :: (ExprTuple t) => Prog t -> IO t
simulate = sampleP

sampleP :: (ExprTuple t) => Prog t -> IO t
sampleP p = do
    env <- samplePNodes emptyEnv block idents
    let env' = Map.filterWithKey (\k _ -> not $ isInternal k) env
    return . fromConstVals $ map (fromJust . evalNodeRef env' block) rets
  where (rets, PBlock block refs _) = runProgExprs p
        idents = [ (Volatile (dagLevel $ topDAG block) i, d)
                 | (i,d) <- zip [0..] $ reverse refs ]

samplePNodes :: Env -> Block -> [(Id, PNode)] -> IO Env
samplePNodes env _ [] = return env
samplePNodes env block ((ident,node):rest) = do
    val <- samplePNode env block node
    let env' = evalBlock block $ Map.insert ident val env
    samplePNodes env' block rest

samplePNode :: Env -> Block -> PNode -> IO ConstVal
samplePNode env block d@(Dist f js (SubrangeT t lo hi)) = do
  x <- samplePNode env block (Dist f js t)
  if flip any (elems' x) (< lo') || any (hi' <) (elems' x)
    then trace ("rejecting OOB sample "++ show x) $
           samplePNode env block d
    else return x
  where lo' | (Just r) <- lo = fromJust $ evalNodeRef env block r
            | otherwise = negativeInfinity
        hi' | (Just r) <- hi = fromJust $ evalNodeRef env block r
            | otherwise = infinity
samplePNode env block (Dist "bernoulli" [p] _) = fromBool <$> bernoulli p'
  where p' = toDouble . fromJust $ evalNodeRef env block p
samplePNode env block (Dist "bernoulliLogit" [l] _) = fromBool <$> bernoulli p'
  where l' = toDouble . fromJust $ evalNodeRef env block l
        p' = 1 / (1 + exp (-l'))
samplePNode env block (Dist "bernoulliLogits" [l] _) = do
  z <- sequence $ map bernoulliLogit l'
  return $ fromList (map fromBool z)
  where l' = map toDouble . toList . fromJust $ evalNodeRef env block l
samplePNode env block (Dist "categorical" cats _) = fromRational <$> categorical (zip ps xs)
  where n = length cats `div` 2
        ps = toDouble . fromJust . evalNodeRef env block <$> take n cats
        xs = toRational . fromJust . evalNodeRef env block <$> drop n cats
samplePNode env block (Dist "cauchy" [m,s] _) = fromDouble <$> cauchy m' s'
  where m' = toDouble . fromJust $ evalNodeRef env block m
        s' = toDouble . fromJust $ evalNodeRef env block s
samplePNode env block (Dist "cauchys" [m,s] (ArrayT _ [_] _)) = fromVector <$> cauchys m' s'
  where m' = toVector . fromJust $ evalNodeRef env block m
        s' = toVector . fromJust $ evalNodeRef env block s
samplePNode env block (Dist "gamma" [a,b] _) = fromDouble <$> gamma a' b'
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
samplePNode env block (Dist "inv_gamma" [a,b] _) = fromDouble <$> invGamma a' b'
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
samplePNode env block (Dist "inv_wishart" [n,w] _) = fromMatrix <$> invWishart n' w'
  where n' = toInteger . fromJust $ evalNodeRef env block n
        w' = toMatrix . fromJust $ evalNodeRef env block w
samplePNode env block (Dist "geometric" [p] _) = fromInteger <$> geometric 0 p'
  where p' = toDouble . fromJust $ evalNodeRef env block p
samplePNode env block (Dist "lkj_corr" [v] (ArrayT _ sh _)) = fromMatrix <$> corrLKJ v' (head sh')
  where v' = toDouble . fromJust $ evalNodeRef env block v
        sh' = evalShape env block sh
samplePNode env block (Dist "normal" [m,s] _) = fromDouble <$> normal m' s'
  where m' = toDouble . fromJust $ evalNodeRef env block m
        s' = toDouble . fromJust $ evalNodeRef env block s
samplePNode env block (Dist "normals" [m,s] (ArrayT _ [_] _)) = fromVector <$> normals m' s'
  where m' = toVector . fromJust $ evalNodeRef env block m
        s' = toVector . fromJust $ evalNodeRef env block s
samplePNode env block (Dist "normals" [m,s] (ArrayT _ [_,_] _)) = fromMatrix <$> normals m' s'
  where m' = toMatrix . fromJust $ evalNodeRef env block m
        s' = toMatrix . fromJust $ evalNodeRef env block s
samplePNode env block (Dist "multi_normal" [m,s] _) = do
  w <- sequence [ normal 0 1 | _ <- [1..n] ]
  let w' = fromList $ map fromDouble w
  return $ m' + chol s' #> w'
  where m' = fromJust $ evalNodeRef env block m
        s' = fromJust $ evalNodeRef env block s
        n = length (toList m')
samplePNode env block (Dist "poisson" [a] _) = fromInteger <$> poisson a'
  where a' = toDouble . fromJust $ evalNodeRef env block a
samplePNode env block (Dist "uniform" [a,b] _) = fromDouble <$> uniform a' b'
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
samplePNode env block (Dist "uniforms" [a,b] (ArrayT _ sh _)) = do
  z <- sequence $ zipWith uniform a' b'
  return $ listArray' (evalShape env block sh) (map fromDouble z)
  where a' = map toDouble . elems' . fromJust $ evalNodeRef env block a
        b' = map toDouble . elems' . fromJust $ evalNodeRef env block b
samplePNode env block (Dist "discreteUniform" [a,b] _) = fromInteger <$> uniform a' b'
  where a' = toInteger . fromJust $ evalNodeRef env block a
        b' = toInteger . fromJust $ evalNodeRef env block b
samplePNode env block (Dist "wishart" [n,v] _) = fromMatrix <$> wishart n' v'
  where n' = toInteger . fromJust $ evalNodeRef env block n
        v' = toMatrix . fromJust $ evalNodeRef env block v

samplePNode env block (Loop shp (Lambda ldag hd) _) =
  listArray' (evalShape env block shp) <$> sequence arr
  where inps = inputs ldag
        block' = deriveBlock ldag block
        arr = [ samplePNode (Map.fromList (zip inps idx) `Map.union` env) block' hd
              | idx <- evalRange env block shp ]

samplePNode env block (HODist "orderedSample" d [n] _) =
  (fromList . sort) <$> sequence [samplePNode env block d | _ <- [1..n']]
  where n' = toInteger . fromJust $ evalNodeRef env block n

samplePNode _ _ d = error $ "samplePNode: unrecognised distribution "++ show d


------------------------------------------------------------------------------
-- DISTRIBUTION CONSTRUCTORS                                                --
------------------------------------------------------------------------------

-- from hsc3
chain :: Monad m => Int -> (b -> m b) -> b -> m b
chain n f = foldr (<=<) return (replicate n f)
loop :: Monad m => a -> (a -> m a) -> m ()
loop s f = do
  s' <- f s
  loop s' f

chainRange :: (Num i, Monad m) => (Int,Int) -> (i -> x -> m x) -> x -> m x
chainRange (lo,hi) f x0 = snd <$> chain (hi-lo+1) g (integer lo, x0)
  where g (i,x) = do
          y <- f i x
          return (i+1,y)

-- Metropolis-Hastings
mh :: (ExprTuple r, Show r) => Prog r -> (r -> Prog r) -> r -> IO r
mh = mhAdjust (const $ LF.logFloat 1)

mhAdjust :: (ExprTuple r, Show r) => (r -> LF.LogFloat) -> Prog r -> (r -> Prog r) -> r -> IO r
mhAdjust adjust target proposal x = do
  y <- sampleP (proposal x)
  putStrLn $ "proposing "++ show y
  let f = density target
      q = density' . proposal
      b = (f y * adjust y) / (f x * adjust x)
      c = q x y / q y x
      a = LF.fromLogFloat (b / c) -- (f y * q y x) / (f x * q x y)
  putStrLn $ "acceptance ratio = "++ show b ++" / "++ show c ++" = "++ show a
  accept <- bernoulli $ if a > 1 then 1 else a
  return $ if accept then y else x

rjmc :: (ScalarType e) => P (Expr e) -> (Expr e -> P (Expr e)) -> Expr e -> P (Expr e)
rjmc target proposal x = do
  y <- proposal x
  let f = pdf target -- TODO: jacobian adjustment for transformed dist
      a = (f y / f x) * rjmcTransRatio proposal x y
  accept <- bernoulli $ ifB (a >* 1) 1 a
  return $ ifB accept y x

rjmcTransRatio :: (ScalarType e) => (Expr e -> P (Expr e)) -> Expr e -> Expr e -> R
rjmcTransRatio q x y = (pu' / pu) * abs (det jacobian)
  where pu  = q x `pdf` y
        pu' = q y `pdf` x
        getAux a b =
          let (rets, PBlock block _ _) = runProgExprs (q a)
              env = solveTuple block rets b emptyEEnv
              p Volatile{} _ = True
              p _ _ = False
          in Map.filterWithKey p env
        u' = getAux y x
        u = let (_,PBlock _ refs _) = runProgExprs (q x)
            in [Var (Volatile 0 i) (typePNode r) | (i,r) <- [0..] `zip` reverse refs]
        x' = let ([ret], PBlock block _ _) = runProgExprs (q x)
             in reDExpr emptyEEnv block ret
        d_ = derivD emptyEEnv
        d a = d_ a . fst . runExpr
        top =   d x' x                     : [d_ x' r          | r <- u]
        bot = [(d v x + (d v y <# d x' x)) : [d v y <> d_ x' r | r <- u]
              | v <- Map.elems u']
        jacobian = Expr . substD (getAux x y) $ blockMatrix (top:bot) :: RMat
