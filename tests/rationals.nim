import unittest

import ../src/ffmpeg

test "maths":
  let a = AVRational(num: 3, den: 4)
  let b = AVRational(num: 3, den: 4)
  check(a + b == AVRational(num: 3, den: 2))
  check(a + a == a * 2)

  let intThree: int64 = 3
  check(intThree / AVRational(3) == AVRational(1))
  check(intThree * AVRational(3) == AVRational(9))

  check(AVRational(num: 9, den: 3).int64 == intThree)
  check(AVRational(num: 10, den: 3).int64 == intThree)
  check(AVRational(num: 11, den: 3).int64 == intThree)

test "strings":
  check(AVRational("42") == AVRational(42))
  check(AVRational("-2/3") == AVRational(num: -2, den: 3))
  check(AVRational("6/8") == AVRational(num: 3, den: 4))
  check(AVRational("1.5") == AVRational(num: 3, den: 2))
