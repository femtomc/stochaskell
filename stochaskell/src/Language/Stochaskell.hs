{-|
Description : Stochaskell main module
Copyright   : (c) David A Roberts, 2015-2019
License     : GPL-3
Maintainer  : d@vidr.cc
Stability   : experimental
-}
module Language.Stochaskell (
  -- * Re-exported modules
    module Prelude
  , module Data.Boolean.Overload
  , module Data.Monoid
  , module Data.Number.Transfinite
  , module GHC.Exts

  -- * Expressions
  , Expression
  -- ** Array manipulation
  , Indexable(..)
  -- ** Recursion
  , foldl, foldr, scanl, scanr
  -- *** Helpers
  , find', findSortedInsertIndex, min', sum'

  -- * Linear algebra
  , InnerProduct(..)
  , LinearOperator(..)
  , Matrix(..)
  , Scalable(..)
  , SquareMatrix(..)
  , Transposable(..)
  , Vector(..)

  -- * Types
  , B, R, Z, BVec, RVec, ZVec, BMat, RMat, ZMat
  -- ** Type casting
  , Cast(..), boolean, integer, real, list
  -- ** Abstract arrays
  , Interval
  , AbstractArray
  , (...)

  -- * Probability distributions
  , P, Distribution, Joint(..)
  -- ** Primitives
  -- *** Boolean
  , Bernoulli, Bernoullis
  , bernoulli, bernoullis, bernoulliLogit, bernoulliLogits
  -- *** Discrete
  , Geometric, NegBinomial, PMF, Poisson
  , geometric, negBinomial, pmf, poisson
  -- *** Continuous
  , Beta, Cauchy, Gamma, InvGamma, Normal, Normals, Uniform, Uniforms
  , beta, cauchy, gamma, invGamma, normal, normals, uniform, uniforms
  -- *** Vector
  , OrderedSample, PoissonProcess
  , orderedSample, poissonProcess
  -- *** Matrix
  , LKJ
  , corrLKJ
  -- ** Logarithmic probability density functions
  , lpdf, lpdfAux
  -- *** Primitives
  , lpdfGamma, lpdfNegBinomial, lpdfNormal, lpdfPoisson
  , lpdfUniform, lpdfDiscreteUniform
  -- ** Transformers
  , mixture, mixture', truncated
  -- ** Iteration
  , chain', chainRange'
  -- ** Pre-defined probabilistic programs
  , lognormal, normalChol, normalsChol, normalCond

  -- * Sampling
  , compileCC, runCC, runStep, simulate
  -- * Inference
  , hmcStan, hmcStanInit, mh, mh', mhRatio, rjmc, rjmcC

  -- ** Miscellaneous
  , module Control.Monad.Guard
  , binarize
  , chain
  , chainRange
  , debug
  , fromRight'
  , interpolate
  , loop
  , mean
  , qfDiag
  , readRealMatrix
  , selectItems
  , slice
  , square
  , stochaskell
  ) where

import Prelude hiding (
  (==),(/=),(<),(>),(<=),(>=),(<*),(*>),(&&),(||),
  max,min,not,foldl,foldr,scanl,scanr)
import Control.Monad.Guard
import Data.Array.Abstract
import Data.Boolean.Overload hiding (boolean) -- TODO: no infix declaration
import Data.Expression hiding (apply,const)
import Data.Expression.Case
import Data.Expression.Const hiding (isScalar)
import Data.Expression.Const.IO
import Data.Monoid
import Data.Number.Transfinite hiding (log,isNaN,isInfinite)
import Data.Program
import Data.Random.Distribution.Abstract
import Data.Version
import GHC.Exts (IsList(..))
import Language.CC
import Language.Stan
import Paths_stochaskell (version)
import System.Directory
import System.Environment
import Util

-- | perform initialisation for interactive use
stochaskell :: IO ()
stochaskell = do
  putStr $ unlines
    [ "Stochaskell, version "++ showVersion version
    , "Copyright (C) 2015-2019 David A Roberts"
    , "This program comes with ABSOLUTELY NO WARRANTY."
    , "This is free software, and you are welcome to redistribute it"
    , "under certain conditions; see the LICENSE for details."
    , ""
    , "Using installation directory at "
    ]
  pwd <- getEnv "STOCHASKELL_DIRECTORY"
  putStrLn $ "  "++ pwd
  setCurrentDirectory pwd
