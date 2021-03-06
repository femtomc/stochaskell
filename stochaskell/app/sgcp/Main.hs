{-# LANGUAGE FlexibleContexts, MonadComprehensions, NoMonomorphismRestriction, RebindableSyntax #-}

module Main where
import Language.Stochaskell
import Language.Stochaskell.Plot
import System.Directory

prefix = "sgcp"

noise = 1e-3

kernelSE lsv lls2 a b =
  exp (lsv - (a - b)^2 / (2 * exp lls2))

gpClassifier :: (R -> R -> R) -> Z -> RVec -> P (RVec,BVec)
gpClassifier kernel n s = do
  let mu  = vector [ 0 | _ <- 1...n ] :: RVec
      cov = matrix [ kernel (s!i) (s!j) + if i == j then noise else 0
                   | i <- 1...n, j <- 1...n ] :: RMat
  g <- normalChol n mu cov
  phi <- joint vector [ bernoulliLogit (g!i) | i <- 1...n ]
  return (g,phi)

poissonProcess' :: R -> R -> P (Z,RVec)
poissonProcess' rate t = do
  n <- poisson (rate * t)
  s <- orderedSample n (uniform 0 t)
  return (n,s)

type State = (R,R,R,Z,RVec,RVec,BVec)

dim :: State -> Z
dim (_,_,_,n,_,_,_) = n

canonicalState :: Z -> State -> State
canonicalState k (lsv,lls2,cap,n,s,g,phi) = (lsv,lls2,cap,n,s',g',phi)
  where (s1,s0) = integer k `splitAt` list s
        (g1,g0) = integer k `splitAt` list g
        (s0',g0') = unzip . sort $ zip s0 g0 :: ([Double],[Double])
        s' = list $ s1 ++ s0' :: RVec
        g' = list $ g1 ++ g0' :: RVec

sgcp :: R -> P State
sgcp t = do
  lsv <- normal 0 1
  lls2 <- normal (log 100) 2
  cap <- gamma 1 1
  (n,s) <- poissonProcess' cap t
  let kernel = kernelSE lsv lls2
  (g,phi) <- gpClassifier kernel n s
  return (lsv,lls2,cap,n,s,g,phi)

stepDown' :: Z -> State -> P (Z,Z,RVec,RVec,BVec)
stepDown' k (lsv,lls2,cap,n,s,g,phi) = do
  i <- uniform (k+1) n
  let n' = n - 1
      s' = s `deleteAt` i
      g' = g `deleteAt` i
      phi' = phi `deleteAt` i
  return (i,n',s',g',phi')

stepDown :: Z -> State -> P State
stepDown k state@(lsv,lls2,cap,n,s,g,phi) = do
  (_,n',s',g',phi') <- stepDown' k state
  return (lsv,lls2,cap,n',s',g',phi')

stepUp' :: R -> Z -> State -> P (R,R,Z,RVec,RVec,BVec)
stepUp' t k (lsv,lls2,cap,n,s,g,phi) = do
  x <- uniform 0 t
  let kernel = kernelSE lsv lls2
  y <- normalCond n kernel noise s g x
  let n' = n + 1
      i = findSortedInsertIndexBound (k+1,n) x s
      s' = s `insertAt` (i, x)
      g' = g `insertAt` (i, y)
      phi' = phi `insertAt` (i, false)
  return (x,y,n',s',g',phi')

stepUp :: R -> Z -> State -> P State
stepUp t k state@(lsv,lls2,cap,n,s,g,phi) = do
  (_,_,n',s',g',phi') <- stepUp' t k state
  return (lsv,lls2,cap,n',s',g',phi')

stepN :: R -> Z -> State -> P State
stepN t k state@(lsv,lls2,cap,n,s,g,phi) = mixture'
  [(1/2, stepUp t k state)
  ,(1/2, if n == k then return state
                   else stepDown k state)
  ]

stepS :: Z -> State -> P State
stepS idx (lsv,lls2,cap,n,s,g,phi) = do
  x <- normal (s!idx) (exp (lls2/2))
  let kernel = kernelSE lsv lls2
  z <- normalCond n kernel noise s g x
  let s' = s `replaceAt` (idx, x)
      g' = g `replaceAt` (idx, z)
  return (lsv,lls2,cap,n,s',g',phi)

stepCap :: R -> State -> P State
stepCap t (lsv,lls2,cap,n,s,g,phi) = do
  let alpha = cast (1 + n) :: R
  cap' <- gamma alpha (1 + t)
  return (lsv,lls2,cap',n,s,g,phi)

sigmoid a = 1 / (1 + exp (-a))

stepN' :: R -> Z -> State -> P (R,State)
stepN' t k state@(lsv,lls2,cap,n,s,g,phi) = do
  c <- bernoulli 0.5
  if c then do -- birth
    (x,y,n',s',g',phi') <- stepUp' t k state
    let state' = (lsv,lls2,cap,n',s',g',phi')
        alpha  = t * cap * sigmoid (-y) / cast (n - k + 1)
    return (alpha,state')
  else if n == k then do
    return (1,state)
  else do -- death
    (i,n',s',g',phi') <- stepDown' k state
    let state' = (lsv,lls2,cap,n',s',g',phi')
        y = (g!i)
        alpha  = cast (n - k) / (t * cap * sigmoid (-y))
    return (alpha,state')

mhN :: R -> Z -> State -> P State
mhN t k state = debug "mhN" <$> do
  (alpha,state') <- stepN' t k state
  let alpha' = rjmc1Ratio (sgcp t) (stepN t k) state state'
  accept <- bernoulli (min' 1 $
    0.5 * (debug "N alpha true" alpha + debug "N alpha auto" alpha'))
  return $ if accept then state' else state

mhS :: R -> Z -> State -> P State
mhS t idx state@(lsv,lls2,cap,n,s,g,phi) = do
  x <- truncated 0 t $ normal (s!idx) (exp (lls2/2))
  let kernel = kernelSE lsv lls2
  z <- normalCond n kernel noise s g x
  let s' = s `replaceAt` (idx, x)
      g' = g `replaceAt` (idx, z)
      state' = (lsv,lls2,cap,n,s',g',phi)
      alpha = sigmoid (-z) / sigmoid (-(g!idx))
      alpha' = rjmc1Ratio (sgcp t) (stepS idx) state state'
  accept <- bernoulli (min' 1 $
    0.5 * (debug "S alpha true" alpha + debug "S alpha auto" alpha'))
  return $ if accept then state' else state

stepMH :: R -> Z -> State -> P State
stepMH t k state = do
  state <- chain' 10 (mhN t k) state
  state <- chainRange' (k + 1, dim state) (mhS t) state
  state <- stepCap t state
  return state

stepRJ :: R -> Z -> State -> P State
stepRJ t k state = do
  state <- chain' 10 (sgcp t `rjmc1` stepN t k) state
  state <- chainRange' (k + 1, dim state) (\idx -> sgcp t `rjmc1` stepS idx) state
  state <- stepCap t state
  return state

stepGP :: R -> State -> IO State
stepGP t (lsv,lls2,cap,n,s,g,phi) = do
  samples <- hmcStanInit 10
    [ (lsv',lls2',g')
    | (lsv',lls2',cap',n',s',g',phi') <- sgcp t,
      cap' == cap, n' == n, s' == s, phi' == phi
    ] (lsv,lls2,g)
  let (lsv',lls2',g') = last samples
  return (lsv',lls2',cap,n,s,g',phi)

genData' :: Double -> Double -> IO [Double]
genData' t cap = do
  n <- poisson (t * cap)
  s <- sequence [ uniform 0 t | _ <- [1..n :: Integer] ]
  let f = [ 2 * exp (-x/15) + exp (-((x-25)/10)^2) | x <- s ]
  phi <- sequence [ bernoulli (y / 2) | y <- f ]
  let dat = s `selectItems` phi
  toSVG (prefix ++"_data") . toRenderable $ do
    plot $ line "truth" [sort $ zip s f]
    plot . points "data" $ zip dat (repeat 1.9)
    plot . points "rejections" $ zip (s `selectItems` map not phi) (repeat 0.1)
  return $ sort dat

initialise :: R -> [Double] -> IO State
initialise t dat = do
  let k = integer (length dat)
      cap = real (2 * k / t)
      n = k + 10
  rej <- sequence [ uniform 0 (real t) | _ <- [1..(n-k)] ]
  let s = fromList $ dat ++ sort rej :: RVec
      phi = fromList $ replicate k True ++ replicate (n-k) False :: BVec
  samples <- hmcStan 1000 [ (lsv,lls2,g) | (lsv,lls2,cap',n',s',g,phi') <- sgcp t,
                            cap' == real cap, n' == integer n, s' == s, phi' == phi ]
  let (lsv,lls2,g) = last samples
  return (lsv,lls2,cap,n,s,g,phi)

main :: IO ()
main = do
 let t = 50
 --setRandomSeed 3
 forM_ [2,4,6,8,10] $ \capTrue -> do
  dat <- genData' t capTrue
  putStrLn $ "data = "++ show dat
  let k = integer (length dat)
      xs = [0.5*x | x <- [0..100]]
  state <- initialise t dat
  stepMH' <- compileCC $ stepMH t k
  createDirectoryIfMissing True (prefix ++"-figs")
  timeStart <- tic
  (_, accum) <- flip (chainRange (1,100)) (state,[]) $ \iter (state, accum) -> do
    putStrLn $ "*** CURRENT STATE: "++ show state

    state <- canonicalState k <$> stepMH' state
    let (lsv,lls2,cap,n,s,g,phi) = state
    let s' = real <$> list s :: [Double]
        phi' = boolean <$> list phi :: [Bool]
    unless (all (\x -> 0 <= x && x <= t) s') $ error ("s = "++ show s)
    unless (and $ take (integer k) phi') $ error ("phi = "++ show phi)

    state <- stepGP t state
    let (lsv,lls2,cap,n,s,g,phi) = state

    let rate = sort $ zip (list s) (list g)
        f = (real cap *) . sigmoid . interpolate rate
        fs = f <$> xs :: [Double]

    toSVG (prefix ++"-figs/"++ show iter) . toRenderable $ do
      plot $ line "rate" [zip xs fs]
      plot . points "data" $ zip (list s) [if y then 0.9 else 0.1 :: Double | y <- toList phi]
    return ((lsv,lls2,cap,n,s,g,phi), fs:accum)
  timeSpent <- toc timeStart
  putStrLn $ "cap = "++ show capTrue ++";\ttime = "++ show timeSpent

  let samples = drop 50 accum
      fmean = mean samples
      fmean2 = mean (map (**2) <$> samples)
      fsd = sqrt <$> fmean2 - map (**2) fmean
  print samples
  toSVG (prefix ++"_mean") . toRenderable $ do
    plot $ line "mean" [zip (xs :: [Double]) fmean]
    plot $ line "sd" [zip (xs :: [Double]) $ zipWith (+) fmean fsd
                     ,zip (xs :: [Double]) $ zipWith (-) fmean fsd]
  return ()
