{-# LANGUAGE FlexibleContexts, MonadComprehensions, RebindableSyntax #-}

module Main where
import Language.Stochaskell
import Language.Stochaskell.Plot

kernel kappa eta part x y =
  eta * exp (- kappa * ((x - y) / part)^2)

kernelCP :: Int -> R -> RVec -> R -> R -> R -> R -> R
kernelCP n t cs kappa eta x y = go 1 where
  go k | integer k == (1::Int) = if x < (cs!1) && y < (cs!1)
                            then kernel kappa eta (cs!1) x y
                            else go 2
       | integer k == n+1 = if (cs!(k-1)) <= x && (cs!(k-1)) <= y
                            then kernel kappa eta (t - cs!(k-1)) x y
                            else 0
       | otherwise        = if (cs!(k-1)) <= x && x < (cs!k)
                            && (cs!(k-1)) <= y && y < (cs!k)
                            then kernel kappa eta (cs!k - cs!(k-1)) x y
                            else go (k+1)
{-
kernelCP n t cs kappa eta x y =
  if i == j then kernel kappa eta (cs' i - cs' (i-1)) x y else 0
  where i = findSortedInsertIndex x cs
        j = findSortedInsertIndex y cs
        cs' i = if i == 0 then 0 else if i == integer (n+1) then t else (cs!i)
-}

covTree :: R -> Z -> RVec -> Int -> RVec -> R -> RVec -> R -> RMat
covTree t n s lmax cs kappa etas eta0 = go lmax where
  go :: Int -> RMat
  --go 0 = matrix [ kernel kappa eta0 t (s!i) (s!j) | i <- 1...n, j <- 1...n ]
  go 0 = 0
  go l = go (l-1) + matrix [ kernelCP c' t cs' kappa (etas!integer l) (s!i) (s!j)
                           | i <- 1...n, j <- 1...n ]
    where c' = 2^l - 1
          cs' = vector [cs!(i * 2^(lmax-l)) | i <- 1...integer c']

mGP :: R -> Z -> Int -> RVec -> P (R,R,RVec,RVec,RVec)
mGP t n lmax s = do
  kappa <- gamma 1 1
  eta0 <- gamma 1 1
  etas <- joint vector [ gamma 1 1 | _ <- 1...integer lmax ]
  let k = 2^lmax - 1
  cs <- orderedSample (integer k) (uniform 0 t)
  mu <- normalChol n (vector [ 0 | _ <- 1...n ]) $
    matrix [ kernel kappa eta0 t (s!i) (s!j) + if i == j then 1e-6 else 0
           | i <- 1...n, j <- 1...n ]
  return (kappa,eta0,etas,cs,mu)

type Model = (R,R,RVec,RVec,RVec,RMat)
prior :: R -> Z -> Z -> Int -> RVec -> R -> P Model
prior t n k lmax s noise = do
  (kappa,eta0,etas,cs,mu) <- mGP t n lmax s
  let cov = covTree t n s lmax cs kappa etas eta0
            + matrix [ if i == j then 1e-6 else 0 | i <- 1...n, j <- 1...n ]
  gs' <- normalsChol k n mu cov
  gs <- joint matrix [ normal (gs'!i!j) noise | i <- 1...k, j <- 1...n ]
  return (kappa,eta0,etas,cs,mu,gs)

mGP' :: R -> Z -> Int -> RVec -> P (R,R,RVec,RVec,RVec)
mGP' t n lmax s = do
  kappa <- gamma 1 1
  eta0 <- gamma 1 1
  etas <- joint vector [ gamma 1 1 | _ <- 1...integer lmax ]
  let k = 2^lmax - 1
  cs <- orderedSample (integer k) (uniform 0 t)
  mu <- normal (vector [ 0 | _ <- 1...n ]) $
    matrix [ kernel kappa eta0 t (s!i) (s!j) + if i == j then 1e-6 else 0
           | i <- 1...n, j <- 1...n ]
  return (kappa,eta0,etas,cs,mu)

prior' :: R -> Z -> Z -> Int -> RVec -> R -> P Model
prior' t n k lmax s noise = do
  (kappa,eta0,etas,cs,mu) <- mGP' t n lmax s
  let cov = covTree t n s lmax cs kappa etas eta0
            + matrix [ if i == j then noise else 0 | i <- 1...n, j <- 1...n ]
  gs <- joint (designMatrix n) [ normal mu cov :: P RVec | _ <- 1...k ]
  return (kappa,eta0,etas,cs,mu,gs)

cut :: Z -> RMat -> Z -> R
cut n w idx = sum' . sum' $
  matrix [ w!i!(j+idx) | i <- 1...idx, j <- 1...(n-idx) ]

assoc :: Z -> RMat -> Z -> R
assoc n w idx = sum' . sum' $
  matrix [ w!i!j       | i <- 1...idx, j <- 1...n ]
assoc' :: Z -> RMat -> Z -> R
assoc' n w idx = sum' . sum' $
  matrix [ w!i!(j+idx) | i <- 1...n,   j <- 1...(n-idx) ]

ncut :: Z -> RMat -> Z -> R
ncut n w idx = cut n w idx * (1/assoc n w idx + 1/assoc' n w idx)
incut :: Z -> RMat -> Z -> R
incut n w idx = 1/ncut n w idx - 1

ecov :: Z -> RMat -> RMat
ecov k gs = z *> (tr' gs' <> gs')
  where z = 1/cast k :: R
        gs' = gs - asRow (z *> sum' gs)

jump :: R -> Z -> Z -> Int -> RVec -> Model -> P Model
jump t n k lmax s (kappa,eta0,etas,cs,mu,gs) = do
  cs' <- go 1 1
  return (kappa,eta0,etas,cs',mu,gs)
  where
  go :: Int -> Int -> P RVec
  go l i | l == lmax = do
    z <- sampleCP l i
    return (cast z)
  go l i = do
    z <- sampleCP l i
    left  <- go (l+1) (2*i - 1)
    right <- go (l+1) (2*i + 1)
    return $ blockVector [left, cast z, right]
  sampleCP :: Int -> Int -> P R
  sampleCP l i = do
    let lo = cp l (i-1)
        hi = cp l (i+1)
        lo' = findSortedInsertIndex lo s - 1
        hi' = findSortedInsertIndex hi s - 1
        n' = hi' - lo'
        ecov' = matrix [ ecov k gs ! (i + lo') ! (j + lo')
                       | i <- 1...n', j <- 1...n']
        ws = vector [ incut n' (abs ecov') i | i <- 1...n'-1 ]
        qs = (1/sum' ws) *> ws
    j <- pmf qs
    uniform (s!j) (s!(j+1))
  cp :: Int -> Int -> R
  cp l i = case i * 2^(lmax-l) of
    0 -> 0
    j | j == 2^lmax -> t
      | otherwise -> cs!integer j

stepHMC :: R -> Z -> Z -> Int -> RVec -> R -> Model -> IO Model
stepHMC t n k lmax s noise (kappa,eta0,etas,cs,mu,gs) = do
  samples <- hmcStanInit 10
    [ (kappa',eta0',etas',mu')
    | (kappa',eta0',etas',cs',mu',gs') <- prior t n k lmax s noise
    , gs' == gs, cs' == cs ]
    (1, 1, list (replicate lmax 1), list (replicate (integer n) 0))
  let (kappa',eta0',etas',mu') = last samples
  return (kappa',eta0',etas',cs,mu',gs)

stepMH :: R -> Z -> Z -> Int -> RVec -> R -> Model -> IO Model
stepMH t n k lmax s noise m =
  prior' t n k lmax s noise `rjmc1` jump t n k lmax s `runStep` m

step :: R -> Z -> Z -> Int -> RVec -> R -> Model -> IO Model
step t n k lmax s noise m = do
  m' <- stepHMC t n k lmax s noise m
  m'' <- stepMH t n k lmax s noise m'
  return m''

genData t n k lmax s noise = do
  (kappa,eta0,etas,cs,mu) <- simulate $ mGP t n lmax (list s)
  let cov = covTree t n (list s) lmax cs kappa etas eta0
            + matrix [ if i == j then noise else 0 | i <- 1...n, j <- 1...n ]
  toPNG "mgp_cov" . renderAxis2 . heatMap' $ toList cov
  gs <- simulate (normalsChol k n mu cov)
  toPNG "mgp_data" . toRenderable $
    sequence [plot $ line "" [sort $ s `zip` g] | g <- toList gs]
  let ecov' = list $ ecov k gs :: RMat
  toPNG "mgp_ecov" . renderAxis2 . heatMap' $ toList (ecov k gs)
  toPNG "mgp_incut" . toRenderable $
    plot $ line "" [[(i, real . incut n (abs ecov') $ integer i) :: (Int,Double)
                    | i <- [1..integer n-1]]]
  return (cs,gs)

main = do
  let t = 10
      n = 100
      lmax = 1
      noise = 8e-3
      k = 10
  let s = linspace (0, real t) $ integer n :: [Double]
  (_,gs) <- genData t n k lmax s noise

  let s' = vector [ t * cast i / cast (n+1) | i <- 1...n ] :: RVec
  {-
  samples <- hmcStanInit 100
    [ (kappa',eta0',etas',mu')
    | (kappa',eta0',etas',cs',mu',gs') <- prior t n k lmax s' noise
    , gs' == gs, cs' == cs ]
    (1, 1, list (replicate lmax 1), list (replicate (integer n) 0))
  let (kappa,eta0,etas,mu) = last samples
  -}
  let m' = (symbol "kappa", symbol "eta0", symbol "etas", symbol "cs", symbol "mu", symbol "gs") :: Model
  svg <- vizIR (prior' t n k lmax s' noise)
  writeFile "mgp_prior.svg" svg
  svg <- vizIR (jump t n k lmax s' m')
  writeFile "mgp_jump.svg" svg
  svg <- vizIR ((prior' t n k lmax s' noise `rjmc1` jump t n k lmax s') m')
  writeFile "mgp_stepmh.svg" svg
  {-
  let m0 = ( 1, 1
           , list (replicate lmax 1)
           , list [0.5]
           , list (replicate (integer n) 0)
           , gs
           )
  samples <- iterateLimit 10 (step t n k lmax s' noise) m0
  let (kappa,eta0,etas,cs,mu,_) = last samples
  let cov = covTree t n (list s) lmax cs kappa etas eta0
            + matrix [ if i == j then noise else 0 | i <- 1...n, j <- 1...n ]
  toPNG "mgp_cov_post" . renderAxis2 . heatMap' $ toList cov
  -}
