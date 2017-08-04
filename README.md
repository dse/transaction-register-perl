# transaction-register-perl

## What is this?

A simple program and Perl module for working with text-file checkbook
registers.

## How to run?

    transaction-register check [FILENAME ...]

## Text File Format

Example:

    account-type     = checking
    starting-balance = 6511.98
    starting-date    = 2017-01-01

    /       01/01   (2250.00)       work
    /       01/03   145.50          car insurance
    /       01/03   318.93          car payment
    /       01/03   79.45           phone bill
    -       01/06   60.00           atm
    -       01/06   5.98            taco bell
            01/08   76.99           cable bill
            01/08   25.97           chi-chi's [preauth 20.97]
            01/08   (20.00)         payment from some guy on ebay
    +       01/15   (2250.00)       work
    +       01/15   232.50          amex credit card payment
    +       01/15   798.53          #2602: mortgage

In this example, your balances would be:

    8218.10 - ledger balance (includes just the posted
              transactions)

    8152.12 - pending balance (adds the pending
              transactions)

    8069.16 - running balance (adds the transactions
              you've made but not yet marked as
              pending or posted)

    8049.16 - worst-case balance (your running balance,
              excluding deposits not yet posted)

    9288.13 - future balance (also includes transactions
              marked with the future flag, i.e., you
              plan to make them but haven't yet done so)

Blank lines, lines containing only whitespace, and lines starting with
optional whitespace then '#' are ignored.

Transactions specify the date, then the amount, then a description
field.  They can optionally start with optional whitespace followed by
a flag:

    /   posted to your account
    -   pending - listed as "pending" in your account
    +   future - transactions you haven't made yet

Dates are specified in one of the following formats:

	06/20/2017
	06/20
	2017-06-20
	06-20

You must specify two digits for the month and day, and if you specify
the year it must be four digits.  day-then-month-then-year formats are
not supported.  If the year is not specified it is relative to the
previously specified transaction date or the starting-date.

With `account-type = checking`, transaction amounts are normally
debits.  In parentheses they are credits.  Dollar signs are optional.
Two-digit cents are required.

To specify a check, start the description field with `#`*number* or
`#`*number*`:` specifying the check number.

`[preauth]` amounts in the description field are mainly used to
confirm your pending balance which will account for the preauth
amount, not the final amount.  For restaurant transactions, preauth
amounts don't include tips.

There is code in `My::Transaction::Register` that supports things I
did not mention here.
