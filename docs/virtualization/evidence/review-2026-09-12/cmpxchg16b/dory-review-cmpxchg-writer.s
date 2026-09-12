.text
.globl _dory_test_ordinary_writer
_dory_test_ordinary_writer:
    mov x3, #0
    mov x4, #0
1:
    add x3, x3, #1
    stlr x3, [x0]
    ldar x5, [x0]
    cmp x5, x3
    cinc x4, x4, ne
    ldarb w5, [x1]
    cbz w5, 1b
    str x3, [x2]
    mov x0, x4
    ret
