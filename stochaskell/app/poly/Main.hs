{-# LANGUAGE RebindableSyntax, MonadComprehensions,
             NoMonomorphismRestriction, FlexibleContexts, TypeFamilies #-}
module Main where
import Language.Stochaskell
import Language.Stochaskell.Plot
import System.Directory

xyData :: [(Double,Double)]
xyData = [
  (-3.89, -39.69),
  (-3.88, -48.17),
  (-3.37, -34.61),
  (-3.16, -33.06),
  (-2.69, -21.92),
  (-2.68, -21.81),
  (-2.53, -23.35),
  (-2.52, -17.84),
  (-2.48, -22.47),
  (-2.35, -17.95),
  (-2.24, -12.22),
  (-2.23, -21.58),
  (-1.85,  -6.26),
  (-1.69, -11.65),
  (-1.61,  -3.83),
  (-1.57,  -2.18),
  (-1.45, -12.09),
  (-1.29,  -8.01),
  (-1.00,  -7.67),
  (-0.97,  -7.01),
  (-0.91,  -6.13),
  (-0.44,  -3.03),
  (-0.32,   0.72),
  (-0.13,   1.71),
  (-0.01,  -2.58),
  ( 0.03,   2.05),
  ( 0.04,   2.38),
  ( 0.07,   1.28),
  ( 0.08,  -0.37),
  ( 0.15,   6.35),
  ( 0.31,  -0.15),
  ( 0.80,   6.37),
  ( 0.84,   2.51),
  ( 1.00,   4.06),
  ( 1.05,   9.79),
  ( 1.17,   0.54),
  ( 1.28,  16.62),
  ( 1.43,   2.09),
  ( 1.52,   4.29),
  ( 1.67,   8.92),
  ( 1.80,   6.28),
  ( 2.37,  11.48),
  ( 2.40,  10.48),
  ( 3.45,  15.14),
  ( 3.45,  13.49),
  ( 3.61,  13.71),
  ( 3.61,  14.59),
  ( 3.89,  12.95),
  ( 3.91,   8.54),
  ( 3.96,  14.60)]

poly :: Z -> Z -> P (RVec,R,RVec,RVec)
poly n d = do
  --x <- joint vector [ uniform (-4) 4 | i <- 1...n ]
  x <- uniforms (vector [ -4 | i <- 1...n ])
                (vector [  4 | i <- 1...n ])
  let design = matrix [ let p = cast (j-1) in (x!i)**p
                      | i <- 1...n, j <- 1...(d+1) ]
  (a,b,y) <- nlm' n (d+1) design
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

model :: Z -> P (RVec,Z,R,RVec,RVec)
model n = do
  d <- geometric 1 (1/10)
  (x,alpha,beta,y) <- poly n d
  return (x,d,alpha,beta,y)

jump :: (RVec,Z,R,RVec,RVec) -> P (RVec,Z,R,RVec,RVec)
jump (x,d,alpha,beta,y) = do
  d' <- mixture' [(1/2, return (d + 1))
                 ,(1/2, return (if d > 1 then d - 1 else d))]
  let beta0 = vector [ if i <= (d+1) then beta!i else 0 | i <- 1...(d'+1) ]
  u <- joint vector [ normal 0 1 | i <- 1...(d'+1) ]
  let beta' = beta0 + u
  return (x,d',alpha,beta',y)

main :: IO ()
main = do
  let n =  integer (length  xyData)
      xData = list (map fst xyData)
      yData = list (map snd xyData)

  -- randomly initialise Markov chain
  let d0 = 1
  samples0 <- hmcStanInit 1000
    [ (alpha,beta) | (x,alpha,beta,y) <- poly n d0, x == xData, y == yData ]
    (1, list [0,0])
  let (alpha0,beta0) = last samples0

  plotPoly 0 n xData yData d0 samples0

  -- run the chain
  loop (1,d0,alpha0,beta0) $ \(t,d,alpha,beta) -> do
    print (t,d,alpha,beta)
    -- 1000 steps of RJMCMC
    (_,d',alphaMH,betaMH,_) <- chain 1000 (runStep $ model n `rjmc1` jump)
                                     (xData,d,alpha,beta,yData)
    -- 1000 steps of HMC via Stan
    samples <- hmcStanInit 1000 [ (alpha,beta) | (x,alpha,beta,y) <- poly n d',
                                                 x == xData, y == yData ]
                           (alphaMH,betaMH)
    plotPoly t n xData yData d' samples
    let (alpha',beta') = last samples
    return (t+1,d',alpha',beta')
  return ()

plotPoly :: Int -> Z -> RVec -> RVec -> Z -> [(R,RVec)] -> IO ()
plotPoly t n xData yData d' samples = do
  createDirectoryIfMissing True "poly-figs"
  toSVG ("poly-figs/"++ show t) . toRenderable $ do
    plot $ points "data" (list xData `zip` list yData)
    setColors [black `withOpacity` 0.05]
    plot $ line ("posterior d="++ show d') $
      map (sort . zip (list xData) . list . extract) $ (samples !!) <$> [0,10..990]
  where design = matrix [ let p = cast (j-1) in (xData!i)**p
                        | i <- 1...n, j <- 1...(d'+1) ]
        extract (_,beta) = design #> beta
