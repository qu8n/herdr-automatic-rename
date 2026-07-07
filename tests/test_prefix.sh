#!/usr/bin/env bash
# Unit tests for the pure "[N] " prefix helpers in automatic-rename.sh. Sourcing the
# engine defines every function but runs nothing (the ar_main guard), so these
# helpers can be exercised directly.

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
. "$here/../automatic-rename.sh"

# ---- ar_strip_prefix: inverse of ar_index_prefix; only strips "[digits] " ----
check "strip single digit"          "api"        "$(ar_strip_prefix '[1] api')"
check "strip multi digit"           "web"        "$(ar_strip_prefix '[12] web')"
check "non-numeric bracket kept"    "[wip] foo"  "$(ar_strip_prefix '[wip] foo')"
check "no prefix untouched"         "plain"      "$(ar_strip_prefix 'plain')"
check "malformed bracket left"      "[1]x] foo"  "$(ar_strip_prefix '[1]x] foo')"
check "keeps inner brackets"        "api [2]"    "$(ar_strip_prefix '[1] api [2]')"

# ---- ar_index_prefix: the carried-forward "[N] " or "" ----
check "index prefix present"        "[3] "       "$(ar_index_prefix '[3] nvim')"
check "index prefix absent"         ""           "$(ar_index_prefix 'nvim')"
check "index prefix non-numeric"    ""           "$(ar_index_prefix '[wip] x')"

# ---- ar_is_placeholder: empty or all-digits ----
ar_is_placeholder "";     check_rc "empty is placeholder"    0 $?
ar_is_placeholder "3";    check_rc "integer is placeholder"  0 $?
ar_is_placeholder "42";   check_rc "42 is placeholder"       0 $?
ar_is_placeholder "nvim"; check_rc "name is not placeholder" 1 $?
ar_is_placeholder "3a";   check_rc "3a is not placeholder"   1 $?

# ---- ar_desired: position -> label under the toggles ----
CLEAR=0; AUTO_INDEX=1
check "desired pos 1"        "[1] api" "$(ar_desired 1 api)"
check "desired pos 9"        "[9] api" "$(ar_desired 9 api)"
check "desired pos 10 bare"  "api"     "$(ar_desired 10 api)"
AUTO_INDEX=0
check "desired index-off"    "api"     "$(ar_desired 1 api)"
AUTO_INDEX=1; CLEAR=1
check "desired clear strips"  "api"    "$(ar_desired 1 api)"
CLEAR=0

# ---- ar_unpark_base: recover a base frozen at a park-temp "[N] base <tid>" ----
check "unpark term_ suffix"     "claude"            "$(ar_unpark_base 'claude term_abc' 'claude')"
check "unpark ws:pane suffix"   "claude"            "$(ar_unpark_base 'claude w1:pA' 'claude')"
check "unpark keeps real name"  "claude session"    "$(ar_unpark_base 'claude session' 'claude')"
check "unpark non-park suffix"  "claude foo"        "$(ar_unpark_base 'claude foo' 'claude')"
check "unpark no detected"      "whatever term_x"   "$(ar_unpark_base 'whatever term_x' '')"

t_summary
