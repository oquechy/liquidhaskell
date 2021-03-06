module Fixme where

import           Prelude                 hiding ( map )

{-@ reflect diff @-}
{-@ diff :: xs:[Int] -> ys:{[Int]|len ys == len xs} -> Int @-}
diff :: [Int] -> [Int] -> Int
diff (x : xs) (y : ys) | x == y = diff xs ys
diff (x : xs) (y : ys) | x /= y = 1 + diff xs ys
diff _ _                        = 0

map :: (Int -> Int) -> [Int] -> [Int]
map _ []       = []
map f (x : xs) = f x : map f xs

{-@ relational map ~ map :: f1:(x1:_ -> _) -> xs1:_ -> _ ~ f2:(x2:_ -> _) -> xs2:_ -> _ 
                         ~~ f1 == f2 => true => Fixme.diff xs1 xs2 == Fixme.diff (r1 f1 xs1) (r2 f2 xs2) @-}
