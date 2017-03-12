{-# LANGUAGE FlexibleContexts, MonadComprehensions, NoMonomorphismRestriction, RebindableSyntax #-}

module Main where
import Prelude hiding ((==),(/=),(<),(>),(<=),(>=),foldr)

import Graphics.Rendering.Chart.Easy ( plot, line, points, def )
import Graphics.Rendering.Chart.Backend.Cairo ( toFile )
import Control.Applicative ()
import Control.Monad.Guard
import Data.Array.Abstract
import Data.Boolean.Overload -- TODO: no infix declaration
import Data.Expression
import Data.Expression.Const
import Data.List hiding (foldr)
import Data.Program
import Data.Random.Distribution.Abstract
import GHC.Exts
import Language.Stan
import Util

kernelSE :: R -> R -> R -> R -> R
kernelSE lsv lls2 a b =
  exp (lsv - (a - b)*(a - b) / (2 * exp lls2))
  + if a == b then 1e-6 else 0

gpClassifier :: (R -> R -> R) -> Z -> RVec -> P (RVec,BVec)
gpClassifier kernel n s = do
  let mu  = vector [ 0 | _ <- 1...n ]
      cov = matrix [ kernel (s!i) (s!j) | i <- 1...n, j <- 1...n ]
  g <- normalChol n mu cov
  phi <- joint vector [ bernoulliLogit (g!i) | i <- 1...n ]
  return (g,phi)

poissonProcess :: R -> R -> P (Z,RVec)
poissonProcess rate t = do
  n <- poisson (rate * t)
  s <- orderedSample n (uniform 0 t)
  return (n,s)

type State = (R,R,R,Z,RVec,RVec,BVec)

dim :: State -> Int
dim (_,_,_,n,_,_,_) = integer n

sgcp :: R -> P State
sgcp t = do
  lsv <- normal 0 1
  lls2 <- normal (log 100) 2
  cap <- gamma 1 1
  (n,s) <- poissonProcess cap t
  let kernel = kernelSE lsv lls2
  (g,phi) <- gpClassifier kernel n s
  return (lsv, lls2, cap, n, s, g, phi)

stepDown :: Z -> Z -> State -> P State
stepDown k n' (lsv,lls2,cap,n,s,g,phi) = do
  i <- uniform (k+1) n'
  let s'   = deleteIndex s i
      g'   = deleteIndex g i
      phi' = deleteIndex phi i
  return (lsv,lls2,cap,n',s',g',phi')

stepUp :: R -> Z -> Z -> State -> P State
stepUp t k n' (lsv,lls2,cap,n,s,g,phi) = do
  x <- uniform 0 t
  let kernel = kernelSE lsv lls2
  z <- normalCond n kernel s g x
  let f i j = if x <= (s!i) then i else j
      i = foldr f n' $ vector [ i | i <- (k+1)...n ]
      s'   = insertIndex s i x
      g'   = insertIndex g i z
      phi' = insertIndex phi i false
  return (lsv,lls2,cap,n',s',g',phi')

stepN :: R -> Z -> State -> P State
stepN t k state@(lsv,lls2,cap,n,s,g,phi) = do
  n' <- categorical [(1/2, n + 1)
                    ,(1/2, if n > k then n - 1 else n)]
  stateUp   <- stepUp t k n' state
  stateDown <- stepDown k n' state
  return $ if n' == (n + 1) then stateUp
      else if n' == (n - 1) then stateDown
      else (lsv,lls2,cap,n',s,g,phi)

stepS :: Z -> State -> P State
stepS idx (lsv, lls2, cap, n, s, g, phi) = do
  x <- normal (s!idx) (exp (lls2/2))
  let kernel = kernelSE lsv lls2
  z <- normalCond n kernel s g x
  let s' = vector [ if i == idx then x else s!i | i <- 1...n ]
      g' = vector [ if i == idx then z else g!i | i <- 1...n ]
  return (lsv, lls2, cap, n, s', g', phi)

stepCap :: R -> State -> P State
stepCap t (lsv, lls2, cap, n, s, g, phi) = do
  let a = cast (1 + n) :: R
  cap' <- gamma a (1 + t)
  return (lsv, lls2, cap', n, s, g, phi)

stepGP :: R -> State -> IO State
stepGP t (lsv,lls2,cap,n,s,g,phi) = do
  samples <- hmcStanInit' 10 [ (lsv',lls2',g') | (lsv',lls2',cap',n',s',g',phi') <- sgcp t,
                                cap' == cap, n' == n, s' == s, phi' == phi ] (lsv,lls2,g)
  let (lsv',lls2',g') = last samples
  return (lsv',lls2',cap,n,s,g',phi)

step :: R -> Z -> State -> IO State
step t k state = do
  state <- chain 10 (sgcp t `mh` stepN t k) state
  state <- chainRange (integer k + 1, dim state)
                      (\i -> sgcp t `mh` stepS i) state
  state <- (sgcp t `mh` stepCap t) state
  state <- stepGP t state
  return state

genData :: R -> IO [Double]
genData t = do
  (_,_,_,_,s,g,phi) <- sampleP (sgcp t)
  toFile def "sgcp_data.png" $ do
    plot $ line "truth" [sort $ zip (toList s) (toList g)]
    plot . points "data" $ zip (toList s) [if y then 2.5 else (-2.5) | y <- toList phi]
  return $ toList s `selectItems` toList phi

genData' :: Double -> IO [Double]
genData' t = do
  let cap = 2
  n <- poisson (t * cap)
  s <- sequence [ uniform 0 t | _ <- [1..n :: Integer] ]
  let f = [ 2 * exp (-x/15) + exp (-((x-25)/10)^2) | x <- s ]
  phi <- sequence [ bernoulli (y / cap) | y <- f ]
  let dat = s `selectItems` phi
  toFile def "sgcp_data.png" $ do
    plot $ line "truth" [sort $ zip s f]
    plot . points "data" $ zip dat (repeat 1.9)
  return $ sort dat

initialise :: R -> [Double] -> IO State
initialise t dat = do
  let k = integer (length dat)
      cap = real (2 * k / t)
      m = 10
      n = k + m
      phi = fromList $ replicate k True ++ replicate m False :: BVec
  rej <- sequence [ uniform 0 (real t) | _ <- [1..m] ]
  let s = fromList $ dat ++ sort rej :: RVec
  samples <- hmcStan [ (lsv,lls2,g) | (lsv,lls2,cap',n',s',g,phi') <- sgcp t,
                       cap' == real cap, n' == integer n, s' == s, phi' == phi ]
  let (lsv,lls2,g) = last samples
  return (lsv,lls2,cap,n,s,g,phi)

main :: IO ()
main = do
  let t = 50
  dat <- genData' t
  let k = integer (length dat)
  state <- initialise t dat
  loop (0,state) $ \(iter,state) -> do
    (lsv,lls2,cap,n,s,g,phi) <- step t k state
    toFile def ("sgcp-figs/"++ show iter ++".png") $ do
      plot $ line "rate" [sort $ zip (list s) (list g)]
      plot . points "data" $ zip (list s) [if y then 2.5 else (-2.5) | y <- toList phi]
    return (iter+1,(lsv,lls2,cap,n,s,g,phi))
