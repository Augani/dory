package main

import (
  "fmt"
  "regexp"
  "runtime"
  "strings"
)

func main() {
  runtime.GOMAXPROCS(4)
  re := regexp.MustCompile(`([a-z]+)([0-9]+)-([a-z]+)`)
  input := strings.Repeat("alpha123-beta gamma456-delta ", 512)
  done := make(chan int, 32)
  for g := 0; g < 32; g++ {
    go func(id int) {
      sum := 0
      for i := 0; i < 4000; i++ {
        m := re.FindAllStringSubmatch(input, -1)
        sum += len(m) + id
        if len(m) != 1024 { panic(fmt.Sprintf("bad matches %d", len(m))) }
        if i%97 == 0 { runtime.Gosched() }
      }
      done <- sum
    }(g)
  }
  total := 0
  for i := 0; i < 32; i++ { total += <-done }
  fmt.Printf("regexpstress-ok total=%d\n", total)
}
