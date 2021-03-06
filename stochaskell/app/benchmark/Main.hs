{-# LANGUAGE FlexibleContexts, MonadComprehensions, NoMonomorphismRestriction,
             RebindableSyntax, TypeFamilies #-}

module Main where
import Language.Stochaskell
import Language.Stochaskell.Expression
import Language.Edward
import Language.PyMC3
import Language.Stan
import System.IO
import System.IO.Error

logreg :: Z -> Z -> P (RMat,RVec,R,BVec)
logreg n d = do
  x <- uniforms (matrix [ -10000 | i <- 1...n, j <- 1...d ])
                (matrix [  10000 | i <- 1...n, j <- 1...d ])
  w <- normals (vector [ 0 | j <- 1...d ]) (vector [ 3 | j <- 1...d ])
  b <- normal 0 3
  let z = (x #> w) + cast b
  y <- bernoulliLogits z
  return (x,w,b,y)

logreg' :: Z -> Z -> P (RMat,RVec,R,BVec)
logreg' n d = do
  -- TODO: automatic vectorisation
  x <- joint matrix [ uniform (-10000) 10000 | i <- 1...n, j <- 1...d ]
  w <- joint vector [ normal 0 3 | j <- 1...d ]
  b <- normal 0 3
  let z = (x #> w) + cast b
  y <- joint vector [ bernoulliLogit (z!i) | i <- 1...n ]
  return (x,w,b,y)

poly :: Z -> Z -> P (RVec,R,RVec,RVec)
poly n d = do
  --x <- joint vector [ uniform (-4) 4 | i <- 1...n ]
  x <- uniforms (vector [ -4 | i <- 1...n ])
                (vector [  4 | i <- 1...n ])
  let design = matrix [ let p = cast (j-1) in (x!i)**p
                      | i <- 1...n, j <- 1...(d+1) ]
  (a,b,y) <- nlm' n (d+1) design
  return (x,a,b,y)

nlm :: Z -> Z -> P (RMat,R,RVec,RVec)
nlm n k = do
  x <- uniforms (matrix [ -10000 | i <- 1...n, j <- 1...k ])
                (matrix [  10000 | i <- 1...n, j <- 1...k ])
  (a,b,y) <- nlm' n k x
  return (x,a,b,y)

nlm' :: Z -> Z -> RMat -> P (R,RVec,RVec)
nlm' n k x = do
  let v = 10
  alpha <- invGamma 1 1

  let mu = vector [ 0 | i <- 1...k ]
      cov = (v*alpha) *> inv (tr' x <> x)
  beta <- normalChol k mu cov

  let z = x #> beta
  --y <- joint vector [ normal (z!i) (sqrt v) | i <- 1...n ]
  y <- normals z (vector [ sqrt v | i <- 1...n ])

  return (alpha,beta,y)

distEucSq :: RVec -> RVec -> RMat
distEucSq a b = asColumn (square a) + asRow (square b) - (2 *> outer a b)

kernelSE' :: R -> R -> Z -> RVec -> RVec -> RMat
kernelSE' lsv lls2 n a b =
  --matrix [ exp (lsv - ((a!i) - (b!j))^2 / (2 * exp lls2))
  --         + if (a!i) == (b!j) then 0.01 else 0
  --       | i <- 1...n, j <- 1...n ]
  exp (cast lsv - distEucSq a b / cast (2 * exp lls2))
  + diag (vector [ 0.01 | i <- 1...n ])

gpClassifier :: (Z -> RVec -> RVec -> RMat) -> Z -> RVec -> P (RVec,BVec)
gpClassifier kernel n s = do
  let mu  = vector [ 0 | _ <- 1...n ]
      cov = kernel n s s
  g <- normalChol n mu cov
  phi <- bernoulliLogits g
  return (g,phi)

gpclas :: Z -> P (R,R,RVec,RVec,BVec)
gpclas n = do
  lsv <- normal 0 1
  lls2 <- normal (log 100) 2
  x <- uniforms (vector [  0 | i <- 1...n ])
                (vector [ 50 | i <- 1...n ])
  (g,phi) <- gpClassifier (kernelSE' lsv lls2) n x
  return (lsv,lls2,x,g,phi)

measerr :: Z -> R -> P (R,R,RVec,RVec,R,R,R,RVec)
measerr n tau = do
  xMu <- uniform (-10) 10
  xSigma <- uniform 0 10
  x <- normals (vector [ xMu | i <- 1...n ])
               (vector [ xSigma | i <- 1...n ])
  xMeas <- normals x (vector [ tau | i <- 1...n ])
  alpha <- normal 0 10
  beta <- normal 0 10
  sigma <- truncated 0 infinity (cauchy 0 5)
  y <- normals (cast alpha + (beta *> x)) (vector [ sigma | i <- 1...n ])
  return (xMu,xSigma,x,xMeas,alpha,beta,sigma,y)

covPrior :: Z -> P RMat
covPrior n = do
  tau <- joint vector [ truncated 0 infinity (cauchy 0 2.5) | i <- 1...n ]
  corr <- corrLKJ 2 (1,n)
  -- TODO: automatically recognise common forms
  --let betaSigma = diag tau <> corr <> diag tau
  return (qfDiag corr tau)

birats :: Z -> Z -> P (RVec,RVec,RMat,RMat,R,RMat)
birats n t = do
  x <- uniforms (vector [ 0 | j <- 1...t ]) (vector [ 50 | j <- 1...t ])
  betaMu <- normals (vector [ 0 | _ <- 1...2 ]) (vector [ 100 | _ <- 1...2 ])
  betaSigma <- covPrior 2
  beta <- joint (designMatrix 2) [ normal betaMu betaSigma :: P RVec | i <- 1...n ]
  let beta' = tr' beta
      yMu = asColumn (beta'!1) + outer (beta'!2) x
      --  = matrix [ (beta'!1!i) + (beta'!2!i) * (x!j) | i <- 1...n, j <- 1...t ]
  ySigma <- truncated 0 infinity (cauchy 0 2.5)
  y <- normals yMu (matrix [ ySigma | i <- 1...n, j <- 1...t ])
  return (x,betaMu,betaSigma,beta,ySigma,y)

covtypeData :: Integer -> Integer -> IO (ConstVal,ConstVal)
covtypeData n d = do
  table <- readRealMatrix "data/covtype.std.data"
  let xData = table `slice` [[i,j] | i <- 1...n, j <- 1...d]
      yData = binarize (1 ==) $ table `slice` [[i,55] | i <- 1...n]
  (xData,yData) `deepseq` putStrLn "loaded covtype data"
  return (xData,yData)

covtype :: IO ()
covtype = do
  let n = 581012; d = 54
  --(xData,wTrue,bTrue,yData) <- simulate (model n d)
  (xData,yData) <- covtypeData n d

  let post = [ (w,b) | (x,w,b,y) <- logreg n d, x == constExpr xData, y == constExpr yData ]
      stepSize = 0.0001

  replicateM_ 11 $ do
    msgStan   <- benchStanHMC   100 10 stepSize post Nothing
    msgPyMC3  <- benchPyMC3HMC  100 10 stepSize post Nothing
    msgEdward <- benchEdwardHMC 100 10 stepSize post Nothing

    putStrLn "==="
    --putStrLn $ "TRUTH:\t"++  show (wTrue,   bTrue)
    putStrLn msgStan
    putStrLn msgPyMC3
    putStrLn msgEdward

covtypeLP (wEd,bEd) (wPM,bPM) (wStan,bStan) = do
  let n = 581012; d = 54
  (xData,yData) <- covtypeData n d
  putStr "Edward: "
  print . logFromLogFloat $ logreg' n d `density'` (constExpr xData, list wEd, real bEd, constExpr yData)
  putStr "PyMC3: "
  print . logFromLogFloat $ logreg' n d `density'` (constExpr xData, list wPM, real bPM, constExpr yData)
  putStr "Stan: "
  print . logFromLogFloat $ logreg' n d `density'` (constExpr xData, list wStan, real bStan, constExpr yData)

poly' :: IO ()
poly' = do
  let n = 50000; d = 7
  putStr "Generating synthetic data... "
  t <- tic
  (xData,alphaTrue,betaTrue,yData) <- simulate (poly n d)
  toc t >>= print
  let design = matrix [ let p = cast (j-1) in (xData!i)**p
                      | i <- 1...n, j <- 1...(d+1) ] :: RMat
      design' = constExpr . fromRight $ eval_ design
  let post = [ (a,b) | (x,a,b,y) <- nlm n (d+1), x == design', y == yData ]
      stepSize = 0.1
  let init = Just (1, list (replicate (d+1) 0))
  putStrLn "Starting inference"
  msgEdward <- benchEdwardHMC 1000 10 stepSize post init
  msgPyMC3  <- benchPyMC3HMC  1000 10 stepSize post init
  msgStan   <- benchStanHMC   1000 10 stepSize post init
  putStrLn "==="
  putStrLn $ "TRUTH:\t"++ show (alphaTrue, betaTrue)
  putStrLn msgStan
  putStrLn msgPyMC3
  putStrLn msgEdward

gpc :: IO ()
gpc = do
  let n = 100
  (lsvTrue,lls2True,xData,_,zData) <- simulate (gpclas n)
  let post = [ (v,l) | (v,l,x,_,z) <- gpclas n, x == xData, z == zData ]
      stepSize = 0.1
  msgEdward <- benchEdwardHMC 1000 10 stepSize post Nothing
  msgPyMC3  <- benchPyMC3HMC  1000 10 stepSize post Nothing
  msgStan   <- benchStanHMC   1000 10 stepSize post Nothing
  putStrLn "==="
  putStrLn $ "TRUTH:\t"++ show (lsvTrue, lls2True)
  putStrLn msgStan
  putStrLn msgPyMC3
  putStrLn msgEdward

measerr' :: IO ()
measerr' = do
  let n = 1000; tau = 0.1
  (xMuTrue,xSigmaTrue,xTrue,xMeasData,alphaTrue,betaTrue,sigmaTrue,yData) <- simulate (measerr n tau)
  let post = [ (xm,xs,x,a,b,s) | (xm,xs,x,xx,a,b,s,y) <- measerr n tau, xx == xMeasData, y == yData ]
      initF = do
        (xm,xs,x,_,a,b,s,_) <- simulate (measerr n tau)
        return (xm,xs,x,a,b,s)
  (samplesStan, samplesPyMC3) <- benchNUTS post initF
  putStrLn "==="
  putStrLn $ "TRUTH:\t"++ show (xMuTrue,xSigmaTrue,xTrue,alphaTrue,betaTrue,sigmaTrue)
  print $ last samplesStan
  print $ last samplesPyMC3

birats' :: IO ()
birats' = do
  let n = 30; t = 5
  (xData,bmTrue,bsTrue,bTrue,ysTrue,yData) <- simulate (birats n t)
  putStrLn $ "xData = "++ show xData
  putStrLn $ "yData = "++ show yData
  let post = [ (bm,bs,b,ys) | (x,bm,bs,b,ys,y) <- birats n t, x == xData, y == yData ]
      initF = do
        (_,bm,bs,b,ys,_) <- simulate (birats n t)
        return (bm,bs,b,ys)
  (samplesStan, samplesPyMC3) <- benchNUTS post initF
  putStrLn "==="
  putStrLn $ "TRUTH:\t"++ show (bmTrue,ysTrue)
  let (bmSample,_,_,yvSample) = last samplesStan
  print (bmSample,yvSample)
  let (bmSample,_,_,yvSample) = last samplesPyMC3
  print (bmSample,yvSample)

benchNUTS post initF = do
  init <- initF
  samplesStan <- hmcStanInit 1000 post init
  let method = defaultPyMC3Inference
        { pmTune = 1000
        , pmDraws = 1000
        , pmChains = Just 1
        , pmFloatX = "float64"
        }
  putStrLn $ pmProgram' method post (Just init)
  samplesPyMC3 <- runPyMC3 method post (Just init)
  return (samplesStan, samplesPyMC3)

benchStanHMC numSamp numSteps stepSize p init = do
  t <- tic
  let method = defaultStanMethod
        { numSamples = numSamp
        , numWarmup = 0
        , adaptEngaged = False
        , hmcEngine = StanStaticHMCEngine
          { intTime = numSteps * stepSize }
        , hmcMetric = StanUnitEMetric
        , hmcStepSize = stepSize
        }
  samples <- drop (numSamp `div` 2) <$> runStan method p init
  s <- toc t
  let means = map mean . transpose $ map (map (fromRight . eval_ . Expression) . fromExprTuple) samples
  return $ "STAN:\t"++ show means ++" took "++ show s ++" for "++ show (length samples) ++" samples"

benchPyMC3HMC numSamp numSteps stepSize p init = do
  let method = defaultPyMC3Inference
        { pmDraws = numSamp
        , pmStep = Just HamiltonianMC
          { pathLength = numSteps * stepSize
          , stepRand = "lambda _:"++ show stepSize
          , stepScale = stepSize
          }
        , pmInit = Nothing
        , pmTune = 0
        , pmChains = Just 1
        }
  putStrLn $ pmProgram' method p init
  t <- tic
  samples <- drop (numSamp `div` 2) <$> runPyMC3 method p init
  s <- toc t
  let aPyMC3 = mean (map fst samples)
      bPyMC3 = mean (map snd samples)
  return $ "PYMC3:\t"++  show (aPyMC3,  bPyMC3)  ++" took "++ show s ++" for "++ show (length samples) ++" samples"

benchEdwardHMC numSamp numSteps stepSize p init = do
  putStrLn $ edProgram numSamp numSteps stepSize p init
  t <- tic
  samples <- drop (numSamp `div` 2) <$> hmcEdward numSamp numSteps stepSize p init
  s <- toc t
  let aEdward = mean (map fst samples)
      bEdward = mean (map snd samples)
  return $ "EDWARD:\t"++ show (aEdward, bEdward) ++" took "++ show s ++" for "++ show (length samples) ++" samples"

retryIOError m = catchIOError m $ \err -> do
  putStrLn "FAILED:"
  print err
  putStrLn "Retrying..."
  retryIOError m

main = do
  hSetBuffering stdout NoBuffering
  replicateM_ 11 $ retryIOError measerr'
