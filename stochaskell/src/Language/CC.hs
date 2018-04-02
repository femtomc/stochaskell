module Language.CC where

import Data.Array.Abstract
import Data.Expression hiding (const)
import Data.Expression.Const hiding (isScalar)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe
import Data.Program
import Util

------------------------------------------------------------------------------
-- UTILITY FUNCTIONS                                                        --
------------------------------------------------------------------------------

ccForLoop :: [Id] -> [Interval NodeRef] -> String -> String
ccForLoop is sh body = concat (zipWith f is sh) ++"{\n"++ body ++"\n}"
  where f i (a,b) = "for(int "++ ccId i ++" = " ++ ccNodeRef a ++"; "++
                                 ccId i ++" <= "++ ccNodeRef b ++"; "++ ccId i ++"++) "


------------------------------------------------------------------------------
-- IDENTIFIERS                                                              --
------------------------------------------------------------------------------

ccId :: Id -> String
ccId (Dummy    level i) = "i_"++ show level ++"_"++ show i
ccId (Volatile level i) = "x_"++ show level ++"_"++ show i
ccId (Internal level i) = "v_"++ show level ++"_"++ show i

ccNodeRef :: NodeRef -> String
ccNodeRef (Var s _) = ccId s
ccNodeRef (Const c _) | dimension c == 0 = show c
ccNodeRef (Index f js) = ccNodeRef f `ccIndex` reverse js
ccNodeRef (Data _ js _) = "make_tuple("++ ccNodeRef `commas` js ++")"

ccIndex :: String -> [NodeRef] -> String
ccIndex  a js = a ++ concat ["["++ ccNodeRef j ++"-1]" | j <- js]
ccIndex' :: String -> [Id] -> String
ccIndex' a js = a ++ concat ["["++ ccId      j ++"-1]" | j <- js]


------------------------------------------------------------------------------
-- TYPES                                                                    --
------------------------------------------------------------------------------

ccType :: Type -> String
ccType IntT = "int"
ccType RealT = "double"
ccType (SubrangeT t _ _) = ccType t
ccType (ArrayT _ sh t) = ccType t ++ replicate (length sh) '*'
ccType (TupleT ts) = "tuple<"++ ccType `commas` ts ++">"
ccType (UnionT ts) = "variant<"++ (ccType . TupleT) `commas` ts ++">"

ccTie :: [Id] -> [Type] -> String
ccTie is ts = concat (zipWith f is ts) ++ "tie("++ ccId `commas` is ++")"
  where f i t = ccType t ++" "++ (ccNodeRef (Var i t)) ++"; "


------------------------------------------------------------------------------
-- NODES                                                                    --
------------------------------------------------------------------------------

ccOperators =
  [("+",   "+")
  ,("-",   "-")
  ,("*",   "*")
  ,("/",   "/")
  ,("==",  "==")
  ,(">",   ">")
  ,(">=",  ">=")
  ,("<",   "<")
  ,("<=",  "<=")
  ]

ccNode :: Map Id PNode -> Label -> Node -> String
ccNode r _ (Apply "getExternal" [Var i _] _) =
  ccPNode (ccId i) . fromJust $ Map.lookup i r
ccNode _ name (Apply "ifThenElse" [a,b,c] _) =
  "if("++ ccNodeRef a ++") "++ name ++" = "++ ccNodeRef b ++"; "++
  "else "++ name ++" = "++ ccNodeRef c ++";"
ccNode _ name (Apply "negate" [i] _) =
  name ++" = -"++ ccNodeRef i ++";"
ccNode _ name (Apply op [i,j] _) | isJust s =
  name ++" = "++ ccNodeRef i ++" "++ fromJust s ++" "++ ccNodeRef j ++";"
  where s = lookup op ccOperators
ccNode _ name (Apply "neg_binomial_lpdf" [i,a,b] _) =
  name ++" = log(boost::math::pdf(boost::math::negative_binomial_distribution<>("++
    ccNodeRef a ++", "++ p ++"), "++ ccNodeRef i ++"));"
  where p = ccNodeRef b ++" / ("++ ccNodeRef b ++" + 1)"
ccNode _ name (Apply f (i:js) _) | (d,"_lpdf") <- splitAt (length f - 5) f =
  name ++" = log(boost::math::pdf(boost::math::"++ d ++ "_distribution<>("++
    ccNodeRef `commas` js ++"), "++ ccNodeRef i ++"));"
ccNode _ name (Apply f js _) =
  name ++" = "++ f ++ "("++ ccNodeRef `commas` js ++");"
ccNode _ name (Array sh (Lambda dag ret) _) =
  ccForLoop (inputs dag) sh $
    ccDAG Map.empty dag ++"\n  "++
    name `ccIndex'` inputs dag ++" = "++ ccNodeRef ret ++";"
ccNode _ name (FoldScan fs lr (Lambda dag ret) seed
               (Var ls s@(ArrayT _ ((Const 1 IntT,n):_) _)) t) =
  name ++ sloc ++" = "++ ccNodeRef seed ++";\n"++
  ccForLoop [idx] [(Const 1 IntT,n)] (unlines
    ["  "++ ccType (typeIndex s) ++" "++ ccId i ++" = "++ ccId ls ++"["++ loc ++"];"
    ,"  "++ ccType (if fs == Fold then t else typeIndex t) ++" "++
              ccId j ++" = "++ name ++ ploc ++";"
    ,       ccDAG Map.empty dag
    ,"  "++ name ++ rloc ++" = "++ ccNodeRef ret ++";"
    ])
  where d = dagLevel dag
        idx = Dummy d 0
        [i,j] = inputs dag
        loc = case lr of
          Left_  -> ccId idx ++"-1"
          Right_ -> ccNodeRef n ++"-"++ ccId idx
        sloc = case fs of
          Fold -> ""
          Scan -> case lr of
            Left_ -> "[0]"
            Right_ -> "["++ ccNodeRef n ++"]"
        (ploc,rloc) = case fs of
          Fold -> ("","")
          Scan -> case lr of
            Left_  -> ("["++ loc ++"-1]", "["++ loc ++"]")
            Right_ -> ("["++ loc ++"]", "["++ loc ++"-1]")
ccNode _ _ node = error $ "unable to codegen node "++ show node

ccPNode :: Label -> PNode -> String
ccPNode name (Dist "bernoulli" args _) =
  name ++" = std::bernoulli_distribution("++ ccNodeRef `commas` args ++")(gen);"
ccPNode name (Dist f args _) =
  name ++" = std::"++ f ++"_distribution<>("++ ccNodeRef `commas` args ++")(gen);"
ccPNode name (Loop sh (Lambda ldag body) _) =
  ccForLoop (inputs ldag) sh $
    let lval = name `ccIndex'` inputs ldag
    in ccDAG Map.empty ldag ++ indent (ccPNode lval body)
ccPNode name (Switch e alts _) =
  "switch("++ ccNodeRef e ++".index()) {\n"++ indent (unlines $ do
    (i, (Lambda dag ret, refs)) <- zip [0..] alts
    ["case "++ show i ++": {",
     "  "++ ccTie (inputs dag) (tss!!i) ++" = get<"++ show i ++">("++ ccNodeRef e ++");",
            ccDAG (pnodes' (dagLevel dag) refs) dag,
     "  "++ name ++" = "++ ccNodeRef ret ++"; break;",
     "}"]) ++"\n}"
  where UnionT tss = typeRef e

ccDAG :: Map Id PNode -> DAG -> String
ccDAG r dag = indent. unlines . flip map (nodes dag) $ \(i,n) ->
  let name = ccId $ Internal (dagLevel dag) i
  in decl name n ++ ccNode r name n
  where decl _ (Apply "getExternal" [i] t) = ccType t ++" "++ (ccNodeRef i) ++"; "
        decl name node = ccType (typeNode node) ++" "++ name ++"; "


------------------------------------------------------------------------------
-- WHOLE PROGRAMS                                                           --
------------------------------------------------------------------------------

ccRead :: Int -> NodeRef -> String
ccRead l e = ccType (typeRef e) ++" "++ ccNodeRef e ++"; "++ ccRead' l e
ccRead' :: Int -> NodeRef -> String
ccRead' _ e | isScalar (typeRef e) = "cin >> "++ ccNodeRef e ++";"
ccRead' l e | (ArrayT _ sh@[(Const 1 _,n)] t) <- typeRef e =
  ccNodeRef e ++" = new "++ ccType t ++"["++ ccNodeRef n ++"];\n"++
  let is = Dummy l <$> [1..length sh] in ccForLoop is sh $
    "  cin >> "++ ccNodeRef e `ccIndex'` is ++";"
ccRead' l e | UnionT tss <- typeRef e =
  ccRead (l+1) c ++"\n"++
  "switch("++ ccNodeRef c ++") {\n"++ indent (unlines $ do
    i  <- [0..length tss - 1]
    let ts = tss !! i
        js = Dummy l <$> [1..length ts]
    ["case "++ show i ++": {",
     indent . unlines $ zipWith ((ccRead (l+1) .). Var) js ts,
     "  "++ ccNodeRef e ++" = make_tuple("++ ccId `commas` js ++");",
     "  break;",
     "}"]) ++"\n}"
  where c = Var (Dummy l 0) IntT

ccPrint :: Int -> NodeRef -> String
ccPrint _ e | isScalar (typeRef e) = "cout << "++ ccNodeRef e ++" << ' ';"
ccPrint l e | (ArrayT _ sh _) <- typeRef e =
  let is = Dummy l <$> [1..length sh] in ccForLoop is sh $
    "  cout << "++ ccNodeRef e `ccIndex'` is ++" << ' ';"
ccPrint l e | UnionT tss <- typeRef e =
  "switch("++ ccNodeRef e ++".index()) {\n"++ indent (unlines $ do
    i  <- [0..length tss - 1]
    let ts = tss !! i
        js = Dummy l <$> [1..length ts]
    ["case "++ show i ++": {",
     "  "++ ccTie js ts ++" = get<"++ show i ++">("++ ccNodeRef e ++");",
     "  cout << "++ show i ++" << ' ';",
     indent . unlines $ zipWith ((ccPrint (l+1) .). Var) js ts,
     "  break;",
     "}"]) ++"\n}"

ccProgram :: (ExprTuple t) => Type -> (Expr a -> Prog t) -> String
ccProgram t prog = unlines
  ["#include <cmath>"
  ,"#include <iostream>"
  ,"#include <random>"
  ,"#include <tuple>"
  ,"#include <boost/math/distributions.hpp>"
  ,"#include <mpark/variant.hpp>"
  ,"using namespace std;"
  ,"using namespace mpark;"
  ,""
  ,"int main() {"
  ,"  random_device rd;"
  ,"  mt19937 gen(rd());"
  ,   indent (ccRead 1 $ Var (Dummy 0 0) t)
  ,   ccDAG (pnodes pb) (topDAG block)
  ,   indent (ccPrint 1 ret)
  ,"  cout << endl;"
  ,"}"
  ]
  where ([ret], pb@(PBlock block _ _)) =
          runProgExprs . prog . expr . return $ Var (Dummy 0 0) t
