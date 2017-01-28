{-# LANGUAGE GADTs, ImpredicativeTypes, FlexibleInstances, ScopedTypeVariables,
             FlexibleContexts, TypeFamilies, MultiParamTypeClasses #-}
module Data.Program where

import Control.Monad.Guard
import Control.Monad.State
import Data.Array.Abstract
import qualified Data.Bimap as Bimap
import Data.Expression
import Data.Expression.Const
import Data.Expression.Eval
import qualified Data.List as List
import Data.Maybe
import qualified Data.Number.LogFloat as LF
import qualified Data.Random as Rand
import Data.Random.Distribution (logPdf)
import Data.Random.Distribution.Abstract
import Data.Random.Distribution.Categorical (Categorical)
import qualified Data.Random.Distribution.Categorical as Categorical
import Data.Random.Distribution.Poisson (Poisson(..))
import Debug.Trace
import GHC.Exts
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
                  , lDefs  :: DAG
                  , lBody  :: PNode
                  , typePNode :: Type
                  }
           deriving (Eq)

instance Show PNode where
  show (Dist d js t) = unwords (d : map show js) ++" :: P "++ show t
  show (Loop sh defs body t) = unwords ["Loop", show sh, show defs, show body, show t]

data PBlock = PBlock { definitions :: Block
                     , actions     :: [PNode]
                     , constraints :: [(NodeRef, ConstVal)]
                     }
            deriving (Eq)
emptyPBlock :: PBlock
emptyPBlock = PBlock emptyBlock [] []

-- lift into Block
liftExprBlock :: MonadState PBlock m => State Block b -> m b
liftExprBlock s = do
    PBlock block rhs given <- get
    let (ret, block') = runState s block
    put $ PBlock block' rhs given
    return ret

data Prog t = Prog { fromProg :: State PBlock t }
type P t = Prog t
instance (Eq t) => Eq (Prog t) where p == q = runProg p == runProg q
runProg :: Prog a -> (a, PBlock)
runProg p = runState (fromProg p) emptyPBlock

type ProgE t = Prog (Expr t)
fromProgE :: ProgE t -> State PBlock NodeRef
fromProgE p = head <$> fromProgExprs p
runProgE :: ProgE t -> (NodeRef, PBlock)
runProgE p = runState (fromProgE p) emptyPBlock

fromProgExprs :: (ExprTuple t) => Prog t -> State PBlock [NodeRef]
fromProgExprs p = do
  es <- fromExprTuple <$> fromProg p
  mapM (liftExprBlock . fromDExpr) es

runProgExprs :: (ExprTuple t) => Prog t -> ([NodeRef], PBlock)
runProgExprs p = runState (fromProgExprs p) emptyPBlock

instance Functor Prog where
    fmap = liftM
instance Applicative Prog where
    pure  = return
    (<*>) = ap
instance Monad Prog where
    return = Prog . return
    act >>= k = Prog $ do
        x <- fromProg act
        fromProg (k x)


------------------------------------------------------------------------------
-- PRIMITIVE DISTRIBUTIONS                                                  --
------------------------------------------------------------------------------

dist :: State Block PNode -> ProgE t
dist s = Prog $ do
    d <- liftExprBlock s
    PBlock block rhs given <- get
    put $ PBlock block (d:rhs) given
    let depth = dagLevel $ head block
        k = length rhs
        name = Volatile depth k
        v = expr . return $ Var name (typePNode d)
    return v

instance Distribution Bernoulli (Expr Double) Prog (Expr Bool) where
    sample (Bernoulli p) = dist $ do
        i <- fromExpr p
        return $ Dist "bernoulli" [i] boolT
    sample (BernoulliLogit l) = dist $ do
        i <- fromExpr l
        return $ Dist "bernoulliLogit" [i] boolT

instance (ScalarType t) => Distribution Categorical (Expr Double) Prog (Expr t) where
    sample cat = dist $ do
        let (ps,xs) = unzip $ Categorical.toList cat
        qs <- mapM fromExpr ps
        ys <- mapM fromExpr xs
        let TypeIs t = typeOf :: TypeOf t
        return $ Dist "categorical" (qs ++ ys) t

instance Distribution Gamma (Expr Double) Prog (Expr Double) where
    sample (Gamma a b) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "gamma" [i,j] RealT

instance Distribution Geometric (Expr Double) Prog (Expr Integer) where
    sample (Geometric p) = dist $ do
        i <- fromExpr p
        return $ Dist "geometric" [i] IntT

instance Distribution Normal (Expr Double) Prog (Expr Double) where
    sample (Normal m s) = dist $ do
        i <- fromExpr m
        j <- fromExpr s
        return $ Dist "normal" [i,j] RealT

instance Distribution Poisson (Expr Double) Prog (Expr Integer) where
    sample (Poisson a) = dist $ do
        i <- fromExpr a
        return $ Dist "poisson" [i] IntT

instance Distribution Uniform (Expr Double) Prog (Expr Double) where
    sample (Uniform a b) = dist $ do
        i <- fromExpr a
        j <- fromExpr b
        return $ Dist "uniform" [i,j] RealT


------------------------------------------------------------------------------
-- LOOPS                                                                    --
------------------------------------------------------------------------------

instance forall r f. ScalarType r =>
         Joint Prog (Expr Integer) (Expr r) (Expr f) where
  joint _ ar = Prog $ do
    sh <- liftExprBlock . sequence . flip map (shape ar) $ \(a,b) -> do
      i <- fromExpr a
      j <- fromExpr b
      return (i,j)
    PBlock block dists given <- get
    let ids = [ Dummy (length block) i | i <- [1..length sh] ]
        p = ar ! [expr . return $ Var i IntT | i <- ids]
        (_, PBlock (dag:block') [act] []) = runState (fromProgE p) $
            PBlock (DAG (length block) ids Bimap.empty : block) [] []
        TypeIs t = typeOf :: TypeOf r
        loopType = ArrayT Nothing sh t
        loop = Loop sh dag act loopType
    put $ PBlock block' (loop:dists) given
    let name = Volatile (length block - 1) (length dists)
    return (expr . return $ Var name loopType :: Expr f)


------------------------------------------------------------------------------
-- CONDITIONING                                                             --
------------------------------------------------------------------------------

type instance ConditionOf (Prog ()) = Expr Bool
instance MonadGuard Prog where
    guard cond = Prog $ do -- TODO: weaker assumptions
        (Var (Internal 0 i) _) <- liftExprBlock (fromExpr cond)
        (PBlock (dag:dags) dists given) <- get
        if i /= length (nodes dag) - 1 then undefined else do
          let (Just (Apply "==" [j, Const a] _)) =
                lookup i $ nodes dag
              dag' = dag { bimap = Bimap.deleteR i (bimap dag) }
          put $ PBlock (dag':dags) dists ((j,a):given)


------------------------------------------------------------------------------
-- PROBABILITY DENSITIES                                                    --
------------------------------------------------------------------------------

density :: (ExprTuple t) => Prog t -> t -> LF.LogFloat
density prog vals = flip densityPBlock pb . flip compose emptyEnv . reverse $
    [ unifyD d v | (d,e) <- zipExprTuple rets vals, let Just v = evalD [] e ]
  where (rets, pb) = runProg prog

densityPBlock :: Env -> PBlock -> LF.LogFloat
densityPBlock env (PBlock block refs _) = product $ do
    (i,d) <- zip [0..] $ reverse refs
    let ident = Volatile (dagLevel $ head block) i
    return $ case lookup ident env of
      Just val -> let p = densityPNode env' block d val
        in trace ("density ("++ show d ++") "++ show val ++" = "++ show p) p
      Nothing  -> trace (show ident ++" is unconstrained") $ LF.logFloat 1
  where env' = evalBlock block env

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
densityPNode env block (Dist "geometric" [t] _) x = p * q^k
  where t' = toDouble . fromJust $ evalNodeRef env block t
        p = LF.logFloat t'
        q = LF.logFloat (1 - t')
        k = toInteger x
densityPNode env block (Dist "normal" [m,s] _) x =
    LF.logToLogFloat $ logPdf (Rand.Normal m' s') (toDouble x)
  where m' = toDouble . fromJust $ evalNodeRef env block m
        s' = toDouble . fromJust $ evalNodeRef env block s
densityPNode env block (Dist "poisson" [l] _) x =
    LF.logToLogFloat $ fromIntegral k * log l' - l' - logFactorial k
  where l' = toDouble . fromJust $ evalNodeRef env block l
        k = toInteger x
densityPNode env block (Dist "uniform" [a,b] _) x =
    LF.logFloat $ if a' <= x' && x' < b' then 1/(b' - a') else 0
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
        x' = toDouble x
densityPNode _ _ (Dist d _ _) _ = error $ "unrecognised density "++ d

densityPNode env block (Loop shp ldag body _) a = product
    [ let p = densityPNode (zip inps i ++ env) block' body (fromRational x)
      in trace ("density ("++ show body ++") "++ show (fromRational x :: Double) ++" = "++ show p) p
    | (i,x) <- evalRange env block shp `zip` entries a ]
  where inps = inputs ldag
        block' = ldag : drop (length block - dagLevel ldag) block


------------------------------------------------------------------------------
-- SAMPLING                                                                 --
------------------------------------------------------------------------------

sampleP :: (ExprTuple t) => Prog t -> IO t
sampleP p = do
    env <- samplePNodes [] block idents
    let env' = filter (not . isInternal . fst) env
    return . fromConstVals . fromJust $ evalTuple env' rets
  where (rets, PBlock block refs _) = runProg p
        idents = [ (Volatile (dagLevel $ head block) i, d)
                 | (i,d) <- zip [0..] $ reverse refs ]

samplePNodes :: Env -> Block -> [(Id, PNode)] -> IO Env
samplePNodes env _ [] = return env
samplePNodes env block ((ident,node):rest) = do
    val <- samplePNode env block node
    let env' = evalBlock block $ (ident, val) : env
    samplePNodes env' block rest

samplePNode :: Env -> Block -> PNode -> IO ConstVal
samplePNode env block (Dist "bernoulli" [p] _) = fromBool <$> bernoulli p'
  where p' = toDouble . fromJust $ evalNodeRef env block p
samplePNode env block (Dist "bernoulliLogit" [l] _) = fromBool <$> bernoulli p'
  where l' = toDouble . fromJust $ evalNodeRef env block l
        p' = 1 / (1 + exp (-l'))
samplePNode env block (Dist "categorical" cats _) = fromRational <$> categorical (zip ps xs)
  where n = length cats `div` 2
        ps = toDouble . fromJust . evalNodeRef env block <$> take n cats
        xs = toRational . fromJust . evalNodeRef env block <$> drop n cats
samplePNode env block (Dist "gamma" [a,b] _) = fromDouble <$> gamma a' (1/b')
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
samplePNode env block (Dist "geometric" [p] _) = fromInteger <$> geometric 0 p'
  where p' = toDouble . fromJust $ evalNodeRef env block p
samplePNode env block (Dist "normal" [m,s] _) = fromDouble <$> normal m' s'
  where m' = toDouble . fromJust $ evalNodeRef env block m
        s' = toDouble . fromJust $ evalNodeRef env block s
samplePNode env block (Dist "poisson" [a] _) = fromInteger <$> poisson a'
  where a' = toDouble . fromJust $ evalNodeRef env block a
samplePNode env block (Dist "uniform" [a,b] _) = fromDouble <$> uniform a' b'
  where a' = toDouble . fromJust $ evalNodeRef env block a
        b' = toDouble . fromJust $ evalNodeRef env block b
samplePNode _ _ (Dist d _ _) = error $ "unrecognised distribution "++ d

-- TODO: maintain shape
samplePNode env block (Loop shp ldag hd _) = fromList <$> sequence arr
  where inps = inputs ldag
        block' = ldag : drop (length block - dagLevel ldag) block
        arr = [ samplePNode (zip inps idx ++ env) block' hd | idx <- evalRange env block shp ]


------------------------------------------------------------------------------
-- DISTRIBUTION CONSTRUCTORS                                                --
------------------------------------------------------------------------------

-- from hsc3
chain :: Monad m => Int -> (b -> m b) -> b -> m b
chain n f = List.foldr (<=<) return (replicate n f)
loop :: Monad m => a -> (a -> m a) -> m ()
loop s f = do
  s' <- f s
  loop s' f

-- Metropolis-Hastings
mh :: (ExprTuple r) => Prog r -> (r -> Prog r) -> r -> IO r
mh target proposal x = do
  y <- sampleP (proposal x)
  let f = density target
      q = density . proposal
      a = LF.fromLogFloat $ (f y * q y x) / (f x * q x y)
  accept <- trace ("acceptance ratio = "++ show a) $
    bernoulli $ if a > 1 then 1 else a
  if accept then return y else return x
