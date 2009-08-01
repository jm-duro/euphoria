-- t_literals.e

include std/unittest.e

-- Hexadecimal literals
test_equal("Hex Lit 1", -4275878552, -#FEDC_BA98)
test_equal("Hex Lit 2", 1985229328, #7654_3210)
test_equal("Hex Lit 3", 11259375, #aB_cDeF)


test_equal("Integer Lit 1", 11259375, 11_259_375)

test_equal("Float Lit 1", 11259.3756, 11_259.375_6)

test_equal("Binary Lit 1", 15, 0b1111)
test_equal("Octal Lit 1", 585, 0t1111)
test_equal("Dec Lit 1", 1111, 0d1111)
test_equal("Hex Lit 4", 4369, 0x1111)

test_equal("Binary Lit 2", 11, 0B1011)
test_equal("Octal Lit 2", 521, 0T1011)
test_equal("Dec Lit 2", 1011, 0D1011)
test_equal("Hex Lit 5", 4113, 0X1011)

/*-------------------------------------------------------
   Extended string literals.
   Make sure each /* allowable */ syntax form is permitted.
-------------------------------------------------------- */
test_equal("Extended string literal 1", "`one` `two`", """`one` `two`""")
test_equal("Extended string literal 2", "\"one\" \"two\"", `"one" "two"`)


/* Test for string which extend over multiple lines. */
integer c1 = 0
integer c2 = 0

/* C1 */ c1 = 1 /* C2 */ c2 = 1 /* eoc */
test_equal("Dual comments", {1,1}, {c1, c2})

sequence _s
_s = `

"three'
'four"

`
test_equal("Extended string literal A", "\n\"three'\n'four\"\n", _s)

_s = `
"three'
'four"
`
test_equal("Extended string literal B", "\"three'\n'four\"", _s)


_s = `"three'
'four"
`
test_equal("Extended string literal C", "\"three'\n'four\"\n", _s)


_s = `
________
        Dear Mr. John Doe, 
        
            I am very happy for your support 
            with respect to the offer of
            help.
        
     Mr. Jeff Doe 
`
sequence t = """
Dear Mr. John Doe, 

    I am very happy for your support 
    with respect to the offer of
    help.

Mr. Jeff Doe 
"""

test_equal("Extended string literal D", t, _s)
     

_s = """
__________________if ( strcmp( "foo", "bar" ) == 1 ) {
                       printf("strcmp works correctly.");
                  }
"""

t = `if ( strcmp( "foo", "bar" ) == 1 ) {
     printf("strcmp works correctly.");
}
`
test_equal("Extended string literal E", t, _s)

test_report()
