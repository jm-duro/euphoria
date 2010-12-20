-- (c) Copyright 2007 Rapid Deployment Software - See License.txt
--
-- The Translator - Acts as a Back-end to the standard Front-end.
--
-- After the front-end is finished, this thing takes over and makes
-- several passes through the IL, trying to optimize things more and more.
-- With each pass, it refines its idea of the type and range of 
-- values of each variable and operand. This allows it to emit C code that
-- is more precise and efficient. It doesn't actually emit the C code
-- until the final pass.

include global.e

constant MAXLEN = MAXINT - 1000000  -- assumed maximum length of a sequence

constant INT16 = #00007FFF,
	 INT15 = #00003FFF

-- Machine Operations - avoid renumbering existing constants 
-- update C copy in execute.h
constant M_COMPLETE = 0,    -- determine Complete Edition
	 M_SOUND = 1,
	 M_LINE = 2,
	 M_PALETTE = 3, 
	 M_PIXEL = 4,       -- obsolete, but keep for now
	 M_GRAPHICS_MODE = 5,
	 M_CURSOR = 6,
	 M_WRAP = 7,
	 M_SCROLL = 8,
	 M_SET_T_COLOR = 9,
	 M_SET_B_COLOR = 10,
	 M_POLYGON = 11,
	 M_TEXTROWS = 12,
	 M_VIDEO_CONFIG = 13,
	 M_GET_MOUSE = 14,
	 M_MOUSE_EVENTS = 15,
	 M_ALLOC = 16,
	 M_FREE = 17,
	 M_ELLIPSE = 18,
	 M_SEEK = 19,
	 M_WHERE = 20,
	 M_GET_PIXEL = 21, -- obsolete, but keep for now
	 M_DIR = 22,
	 M_CURRENT_DIR = 23,
	 M_MOUSE_POINTER = 24,
	 M_GET_POSITION = 25,
	 M_WAIT_KEY = 26,
	 M_ALL_PALETTE = 27,
	 M_GET_DISPLAY_PAGE = 28,
	 M_SET_DISPLAY_PAGE = 29,
	M_GET_ACTIVE_PAGE = 30,
	M_SET_ACTIVE_PAGE = 31,
	M_ALLOC_LOW    = 32,
	M_FREE_LOW     = 33,
	M_INTERRUPT    = 34,
	M_SET_RAND     = 35,
	M_USE_VESA     = 36,
	M_CRASH_MESSAGE = 37,
	M_TICK_RATE    = 38,
	M_GET_VECTOR   = 39,
	M_SET_VECTOR   = 40,
	M_LOCK_MEMORY  = 41,
	M_ALLOW_BREAK  = 42,
	M_CHECK_BREAK  = 43,
	M_MEM_COPY     = 44,  -- obsolete, but keep for now
	M_MEM_SET      = 45,  -- obsolete, but keep for now
	M_A_TO_F64     = 46,
	M_F64_TO_A     = 47,
	M_A_TO_F32     = 48,
	M_F32_TO_A     = 49,
	M_OPEN_DLL     = 50,
	M_DEFINE_C     = 51,
	M_CALLBACK     = 52,
	M_PLATFORM     = 53,  -- obsolete, but keep for now
	M_FREE_CONSOLE = 54,
	M_INSTANCE     = 55,
	M_DEFINE_VAR   = 56,
	M_CRASH_FILE   = 57,
	M_GET_SCREEN_CHAR = 58,
	M_PUT_SCREEN_CHAR = 59,
	M_FLUSH        = 60,
	M_LOCK_FILE    = 61,
	M_UNLOCK_FILE  = 62,
	M_CHDIR        = 63,
	M_SLEEP        = 64,
	M_BACKEND      = 65

constant INIT_CHUNK = 2500 -- maximum number of literals to 
			   -- initialize in one init-*.c file (one routine)

global sequence target   -- struct minmax
target = {0, 0}

sequence in_loop

function min(atom a, atom b) 
    if a < b then 
	return a
    else
	return b
    end if
end function

function max(atom a, atom b) 
    if a > b then 
	return a
    else
	return b
    end if
end function

function abs(atom a)
    if a < 0 then
	return -a
    else
	return a
    end if
end function

function savespace() 
-- should try to save space and reduce complexity
   return length(in_loop) = 0 and (CurrentSub = TopLevelSub or
	  length(SymTab[CurrentSub][S_CODE]) > (MAX_CFILE_SIZE/2))
end function

function BB_temp_type(integer var)
-- return the local type for a temp *name*, based on BB info */
    integer t, tn
    
    tn = SymTab[var][S_TEMP_NAME]
    for i = length(BB_info) to 1 by -1 do
	if SymTab[BB_info[i][BB_VAR]][S_MODE] = M_TEMP and
	   SymTab[BB_info[i][BB_VAR]][S_TEMP_NAME] = tn then
	    t = BB_info[i][BB_TYPE]
	    if t <= 0 or t > TYPE_OBJECT then
		InternalErr("Bad BB_temp_type")
	    end if
	    return t
	end if
    end for
    -- no info in BB, so fall back to global temp name info
    return or_type(TYPE_INTEGER,   -- for initialization = 0
		   temp_name_type[SymTab[var][S_TEMP_NAME]][T_GTYPE])
end function

function BB_temp_elem(integer var)
-- return the local element type for a temp *name*, based on BB info */
    integer t, tn
    
    tn = SymTab[var][S_TEMP_NAME]
    for i = length(BB_info) to 1 by -1 do 
	if SymTab[BB_info[i][BB_VAR]][S_MODE] = M_TEMP and
	   SymTab[BB_info[i][BB_VAR]][S_TEMP_NAME] = tn then
	    t = BB_info[i][BB_ELEM]
	    if t = TYPE_NULL then
		t = TYPE_OBJECT
	    end if
	    if t <= 0 or t > TYPE_OBJECT then
		InternalErr("Bad BB_elem type")
	    end if
	    return t
	end if
    end for
    -- no info in BB, so fall back to global temp name info
    return TYPE_OBJECT -- Later we might track temp element types globally
end function

function BB_var_elem(integer var)
-- return the local element type of a var, based on BB info */
    integer t
    
    for i = length(BB_info) to 1 by -1 do 
	if SymTab[BB_info[i][BB_VAR]][S_MODE] = M_NORMAL and
	    BB_info[i][BB_VAR] = var then
	    t = BB_info[i][BB_ELEM]
	    if t < 0 or t > TYPE_OBJECT then
		InternalErr("Bad BB_elem")
	    end if
	    if t = TYPE_NULL then   -- var has only been read
		return TYPE_OBJECT
	    else
		return t
	    end if
	end if
    end for
    return TYPE_OBJECT
end function

function BB_var_seqlen(integer var)
-- return the sequence length of a var, based on BB info. */
    for i = length(BB_info) to 1 by -1 do 
	if SymTab[BB_info[i][BB_VAR]][S_MODE] = M_NORMAL and
	   BB_info[i][BB_VAR] = var then
	    if BB_info[i][BB_TYPE] != TYPE_SEQUENCE and -- makes sense? (was or)
	       BB_info[i][BB_TYPE] != TYPE_OBJECT then  
		return NOVALUE
	    end if
	    return BB_info[i][BB_SEQLEN]
	end if
    end for
    return NOVALUE
end function

function SeqElem(integer x) 
-- the type of all elements of a sequence
    symtab_index s
    integer t, local_t

    s = x
    t = SymTab[s][S_SEQ_ELEM]
    if t < 0 or t > TYPE_OBJECT then
	InternalErr("Bad seq_elem")
    end if
    if SymTab[s][S_MODE] != M_NORMAL then
	return t
    end if
    -- check local BB info for vars only 
    local_t = BB_var_elem(x)
    if local_t = TYPE_OBJECT then 
	return t
    end if
    if t = TYPE_INTEGER then
	return TYPE_INTEGER
    end if
    return local_t
end function

function SeqLen(integer x) 
-- the length of a sequence
    symtab_index s
    atom len, local_len
    
    s = x
    len = SymTab[s][S_SEQ_LEN]
    if SymTab[s][S_MODE] != M_NORMAL then
	return len
    end if
    -- check local BB info for vars only - min has local seq_len
    local_len = BB_var_seqlen(x)
    if local_len = NOVALUE then 
	return len
    else
	return local_len
    end if
end function

function ObjMinMax(integer x) 
-- the value of an integer constant or variable
    symtab_index s
    sequence t, local_t
    
    s = x
    t = {SymTab[s][S_OBJ_MIN], SymTab[s][S_OBJ_MAX]}

    if SymTab[s][S_MODE] != M_NORMAL then
	return t
    end if
    
    -- check local BB info for vars only 
    local_t = BB_var_obj(x)
    if local_t[MIN] = NOVALUE then 
	return t
    else
	return local_t
    end if
end function

function IntegerSize(integer pc, integer var)
-- return TRUE if var (or temp) must be in the 
-- magnitude range of a Euphoria integer for this op 
-- (N.B. although it could be in double form)
    integer op
    
    op = Code[pc]
    
    if find(op, {ASSIGN_OP_SUBS, PASSIGN_OP_SUBS, RHS_SUBS_CHECK, RHS_SUBS,
		 RHS_SUBS_I, ASSIGN_SUBS_CHECK, ASSIGN_SUBS,
		 ASSIGN_SUBS_I}) then   -- FOR NOW - ADD MORE
	return Code[pc+2] = var
    
    elsif op = LHS_SUBS or op = LHS_SUBS1 or op = LHS_SUBS1_COPY then
	return Code[pc+2] = var
    
    elsif op = REPEAT then
	return Code[pc+2] = var
    
    elsif op = RHS_SLICE or op = ASSIGN_SLICE then 
	return Code[pc+2] = var or Code[pc+3] = var
    
    elsif op = POSITION then
	return Code[pc+1] = var or Code[pc+2] = var
    
    elsif op = MEM_COPY or op = MEM_SET then
	return Code[pc+3] = var
    
    else        
	return FALSE
    
    end if
end function

-- we map code indexes into small integers for better readability
sequence label_map
label_map = {}

function find_label(integer addr)
-- get the label number, given the address,
-- or create a new label number
    integer m
    
    m = find(addr, label_map)
    if m then
	return m
    end if
    
    label_map = append(label_map, addr)
    return length(label_map)
end function

function forward_branch_into(integer addr1, integer addr2)
-- is there a possible forward branch into the code from addr1 to addr2 
-- inclusive? i.e. is there a label defined already in that range
-- Note: NOP1 defines a label at the *next* location - be careful
-- not to delete it accidentally
    for i = 1 to length(label_map) do
	if label_map[i] >= addr1 and label_map[i] <= addr2+1 then
	    return TRUE
	end if
    end for
    return FALSE
end function

procedure Label(integer addr)
-- emit a label, and start a new basic block
    integer label_index
    
    NewBB(0, E_ALL_EFFECT, 0)
    label_index = find_label(addr)
    c_printf("L%x:\n", label_index)
end procedure               

procedure Goto(integer addr)
-- emits a C goto statement.
-- does branch straightening
    integer label_index, br, new_addr

    while TRUE do
	new_addr = addr
	br = Code[new_addr]
	while (br = NOP1 or br = STARTLINE) and new_addr < length(Code)-2 do
	    -- skip no-ops
	    if br = NOP1 then
		new_addr += 1
	    else
		new_addr += 2
	    end if
	    br = Code[new_addr]
	end while
    
	if addr < 6 or 
	   not find(Code[addr-5], {ENDFOR_INT_UP1, ENDFOR_GENERAL}) 
--         or
--         SymTab[Code[addr-2]][S_GTYPE] = TYPE_INTEGER  -- could get subscript error
	    then 
	    -- careful: general ENDFOR might emit a label followed by 
	    -- code that shouldn't be skipped
	    if find(br, {ELSE, ENDWHILE, EXIT}) then
		addr = Code[new_addr+1]
	    else
		exit
	    end if
	else
	    exit
	end if
    end while
    
    label_index = find_label(addr)
    c_stmt0("goto ")
    c_printf("L%x;\n", label_index)
end procedure

function BB_exist(integer var)
-- return TRUE if a var or temp was read or written 
-- already in the current BB 
    for i = length(BB_info) to 1 by -1 do 
	if BB_info[i][BB_VAR] = var then
	    return TRUE
	end if
    end for
    return FALSE
end function

procedure c_fixquote(sequence c_source)
-- output a string of C source code with backslashes before quotes
    integer c
    
    if emit_c_output then
	for p = 1 to length(c_source) do
	    c = c_source[p]
	    if c = '"' or c = '\\' then
		puts(c_code, '\\')
	    end if
	    if c != '\n' and c != '\r' then
		puts(c_code, c)
	    end if
	end for
    end if
end procedure

function IsParameter(symtab_index v)
-- TRUE if v is a parameter of the current subroutine
    if SymTab[v][S_MODE] = M_NORMAL and 
       SymTab[v][S_SCOPE] = SC_PRIVATE and 
       SymTab[v][S_VARNUM] < SymTab[CurrentSub][S_NUM_ARGS] then
	return TRUE
    else
	return FALSE
    end if
end function

procedure CRef(integer v)
-- Ref a var or temp in the quickest way
    if TypeIs(v, TYPE_INTEGER) then 
	return
    end if
    if TypeIs(v, {TYPE_DOUBLE, TYPE_SEQUENCE}) then
	c_stmt0("RefDS(")
    else 
	c_stmt0("Ref(") -- TYPE_ATOM, TYPE_OBJECT
    end if
    LeftSym = TRUE
    CName(v)
    c_puts(");\n")
end procedure

procedure CRefn(integer v, integer n)
-- Ref a var or temp n times in the quickest way 
    if TypeIs(v, TYPE_INTEGER) then 
	return
    end if
    
    if TypeIs(v, {TYPE_DOUBLE, TYPE_SEQUENCE}) then
	c_stmt0("RefDSn(")
    else 
	c_stmt0("Refn(") -- TYPE_ATOM, TYPE_OBJECT
    end if
    
    LeftSym = TRUE
    CName(v)
    c_printf(", %d);\n", n)
end procedure

function target_differs(integer target, integer opnd1, integer opnd2, 
			integer opnd3)
-- see if target is not used as an operand - it can be DeRef'd early
    if SymTab[target][S_MODE] = M_NORMAL then
	return target != opnd1 and target != opnd2 and target != opnd3

    elsif SymTab[target][S_MODE] = M_TEMP then
	if (opnd1 = 0 or
	    SymTab[target][S_TEMP_NAME] != SymTab[opnd1][S_TEMP_NAME]) and
	   (opnd2 = 0 or
	    SymTab[target][S_TEMP_NAME] != SymTab[opnd2][S_TEMP_NAME]) and
	   (opnd3 = 0 or
	    SymTab[target][S_TEMP_NAME] != SymTab[opnd3][S_TEMP_NAME]) then
	    return TRUE
	else
	    return FALSE
	end if
	
    else
	return FALSE
    
    end if
end function

sequence deref_str
integer deref_type
integer deref_elem_type
integer deref_short

procedure CSaveStr(sequence target, integer v, integer a, integer b, integer c)
-- save a value (to be deref'd) in immediate target 
-- if value isn't known to be an integer 
    boolean deref_exist
    
    deref_str = target
    deref_exist = FALSE
    
    if SymTab[v][S_MODE] = M_TEMP then
	deref_type = BB_temp_type(v)
	deref_elem_type = BB_temp_elem(v)

    elsif SymTab[v][S_MODE] = M_NORMAL then 
	deref_type = GType(v)
	if deref_type != TYPE_INTEGER then
	    deref_exist = BB_exist(v)
	end if
	deref_elem_type = SeqElem(v)

    else 
	deref_type = TYPE_INTEGER
    
    end if

    deref_short = (deref_type = TYPE_DOUBLE or 
		   deref_type = TYPE_SEQUENCE) and
		 (SymTab[v][S_MODE] = M_TEMP or
		  IsParameter(v) or 
		  deref_exist)

    if deref_type != TYPE_INTEGER then
	if target_differs(v, a, b, c) then
	    -- target differs from operands - can DeRef it immediately
	    if savespace() then
		c_stmt0("DeRef1(")  -- less machine code

	    else  
		if deref_short then 
		    -- we know it's initialized to an actual pointer
		    if deref_elem_type = TYPE_INTEGER then  -- could do all-sequence/all-double dref later
			c_stmt0("DeRefDSi(")
		    else    
			c_stmt0("DeRefDS(")
		    end if
		else 
		    if deref_elem_type = TYPE_INTEGER then
			c_stmt0("DeRefi(")
		    else
			c_stmt0("DeRef(")
		    end if
		end if
	    end if
	    LeftSym = TRUE
	    CName(v)
	    c_puts(");\n")
	    deref_str = ""  -- cancel it

	else 
	    c_stmt0(target)
	    c_puts(" = ")
	    CName(v)
	    c_puts(";\n")
	
	end if
    end if
end procedure                               

procedure CDeRefStr(sequence s)
-- DeRef a string name  - see CSaveStr()
    if length(deref_str) = 0 then
	return
    end if
	
    if not equal(s, deref_str) then
	CompileErr("internal: deref problem")
    end if
    
    if deref_type != TYPE_INTEGER then
	if savespace() then
	    c_stmt0("DeRef1(")  -- less machine code

	else 
	    if deref_short then
		-- we know it's initialized to an actual pointer
		if deref_elem_type = TYPE_INTEGER then 
		-- could do all-sequence/all-double dref later
		    c_stmt0("DeRefDSi(")
		else    
		    c_stmt0("DeRefDS(")
		end if
	    else 
		if deref_elem_type = TYPE_INTEGER then
		    c_stmt0("DeRefi(")
		else
		    c_stmt0("DeRef(")
		end if
	    end if
	end if
	c_puts(s)
	c_puts(");\n")
    end if
end procedure

procedure CDeRef(integer v) 
-- DeRef a var or temp
    integer temp_type, elem_type
    
    if SymTab[v][S_MODE] = M_TEMP then
	temp_type = BB_temp_type(v)
	elem_type = BB_temp_elem(v)
	if temp_type = TYPE_INTEGER then
	    return
	end if
	if savespace() then
	    c_stmt0("DeRef1(")  -- less machine code
	
	else 
	    if temp_type = TYPE_DOUBLE or 
	       temp_type = TYPE_SEQUENCE then
		c_stmt0("DeRefDS(")
	       
	    else 
		c_stmt0("DeRef(")  -- TYPE_ATOM, TYPE_OBJECT, TYPE_NULL
	    end if
	end if

    else 
	-- var
	if TypeIs(v, TYPE_INTEGER) then 
	    return
	end if
	
	elem_type = SeqElem(v)
	
	if savespace() then
	    c_stmt0("DeRef1(")  -- less machine code

	else 
	    if TypeIs(v, {TYPE_DOUBLE, TYPE_SEQUENCE}) and
		(IsParameter(v) or BB_exist(v)) then
		-- safe: parameters are always initialized
		if elem_type = TYPE_INTEGER then
		    c_stmt0("DeRefDSi(")
		else
		    c_stmt0("DeRefDS(")
		end if

	    else 
		-- TYPE_ATOM, TYPE_OBJECT
		if elem_type = TYPE_INTEGER then
		    c_stmt0("DeRefi(")
		else
		    c_stmt0("DeRef(")
		end if
	    end if
	end if
    end if
    
    LeftSym = TRUE
    CName(v)
    c_puts(");\n")
end procedure

procedure CUnaryOp(integer pc, sequence op_int, sequence op_gen)
-- handle several unary ops where performance of 
-- calling a routine for int case, and calling
-- unary_op() for non-ints is acceptable
    integer target_type
    
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	-- test for integer
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    end if
    
    if TypeIsNot(Code[pc+1], {TYPE_DOUBLE, TYPE_SEQUENCE}) then
	-- handle integer
	c_stmt("@ = ", Code[pc+2])
	c_puts(op_int)
	temp_indent = -indent
	c_stmt("(@);\n", Code[pc+1])
    end if
    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("else\n")
    end if
    
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	-- handle double or sequence
	c_stmt("@ = unary_op(", Code[pc+2])
	c_puts(op_gen)
	temp_indent = -indent
	c_stmt(", @);\n", Code[pc+1])
    end if   
    CDeRefStr("_0")
    
    if TypeIs(Code[pc+1], TYPE_INTEGER) then
	target_type = TYPE_ATOM
    else
	target_type = GType(Code[pc+1])
    end if
    SetBBType(Code[pc+2], target_type, novalue, TYPE_OBJECT)
end procedure

procedure seg_peek1(integer target, integer source, integer mode)
-- emit code for a single-byte peek  - uses _1 as a temp 
    if atom(dj_path) then
	-- WATCOM: memory is seamless */     
	if mode = 1 then
	    c_stmt("@ = *(unsigned char *)(unsigned long)(DBL_PTR(@)->dbl);\n",
		    {target, source})
	else 
	    c_stmt("@ = *(unsigned char *)@;\n", {target, source})
	end if

    else 
	-- DJGPP: low memory is in a separate segment,
	--        high memory is always >= one million 
	-- OPTIMIZE if source is a constant 
	if mode = 1 then
	    c_stmt("_1 = (int)(unsigned)DBL_PTR(@)->dbl;\n", source)
	    c_stmt0("if ((unsigned)_1 > LOW_MEMORY_MAX)\n")
	    c_stmt("@ = *(unsigned char *)_1;\n", target)
	    c_stmt0("else\n")
	    c_stmt("@ = _farpeekb(_go32_info_block.selector_for_linear_memory, (unsigned)_1);\n", 
		    target)

	elsif mode = 2 then
	
	else 
	    c_stmt("if ((unsigned)@ > LOW_MEMORY_MAX)\n", source)
	    c_stmt("@ = *(unsigned char *)@;\n", {target, source})
	    c_stmt0("else\n")
	    c_stmt("@ = _farpeekb(_go32_info_block.selector_for_linear_memory, (unsigned)@);\n", 
		    {target, source})
	end if
    end if
end procedure

procedure seg_peek4(integer target, integer source, boolean dbl)
-- emit code for a 4-byte signed or unsigned peek
    if atom(dj_path) then
	-- WATCOM: memory is seamless
	if dbl then
	    c_stmt("@ = *(unsigned long *)(unsigned long)(DBL_PTR(@)->dbl);\n",
		    {target, source})
	
	else
	    c_stmt("@ = *(unsigned long *)@;\n", {target, source})
	end if

    else 
	-- DJGPP: low memory is in a separate segment,
	--        high memory is always >= one million
	-- OPTIMIZE if source is a constant
	if dbl then
	    c_stmt("_1 = (int)(unsigned)DBL_PTR(@)->dbl;\n", source)
	    c_stmt0("if ((unsigned)_1 > LOW_MEMORY_MAX)\n")
	    c_stmt("@ = *(unsigned long *)_1;\n", target)
	    c_stmt0("else\n")
	    c_stmt("@ = _farpeekl(_go32_info_block.selector_for_linear_memory, (unsigned)_1);\n", 
		    target)
	else 
	    c_stmt("if ((unsigned)@ > LOW_MEMORY_MAX)\n", source)
	    c_stmt("@ = *(unsigned long *)@;\n", {target, source})
	    c_stmt0("else\n")
	    c_stmt("@ = _farpeekl(_go32_info_block.selector_for_linear_memory, (unsigned)@);\n", 
		    {target, source})
	end if
    end if
end procedure

procedure seg_poke1(integer source, boolean dbl)
-- poke a single byte value into poke_addr
    if atom(dj_path) then
	-- WATCOM etc.
	if dbl then
	    if EWINDOWS and atom(bor_path) and atom(wat_path) then
		-- do it in two steps to work around an Lcc bug:
		c_stmt("_1 = (signed char)DBL_PTR(@)->dbl;\n", source)
		c_stmt0("*poke_addr = _1;\n")
	    else
		c_stmt("*poke_addr = (signed char)DBL_PTR(@)->dbl;\n", source)
	    end if
	else
	    c_stmt("*poke_addr = (unsigned char)@;\n", source)
	end if
    
    else 
	-- DJGPP
	if dbl then
	    c_stmt0("if ((unsigned)poke_addr > LOW_MEMORY_MAX)\n")
	    c_stmt("*poke_addr = (signed char)DBL_PTR(@)->dbl;\n", source)
	    c_stmt0("else\n")
	    c_stmt("_farpokeb(_go32_info_block.selector_for_linear_memory, (unsigned long)poke_addr, (unsigned char)DBL_PTR(@)->dbl);\n", 
		    source)

	else 
	    c_stmt0("if ((unsigned)poke_addr > LOW_MEMORY_MAX)\n")
	    c_stmt("*poke_addr = (unsigned char)@;\n", source)
	    c_stmt0("else\n")
	    c_stmt("_farpokeb(_go32_info_block.selector_for_linear_memory, (unsigned long)poke_addr, (unsigned char)@);\n", 
		    source)
	end if
    end if
end procedure

procedure seg_poke4(integer source, boolean dbl)
-- poke a 4-byte value into poke4_addr 
    if atom(dj_path) then
	-- WATCOM etc. 
	if dbl then
	    if EWINDOWS and atom(bor_path) and atom(wat_path) then
		-- do it in two steps to work around an Lcc bug:
		c_stmt("_1 = (unsigned long)DBL_PTR(@)->dbl;\n", source)
		c_stmt0("*poke4_addr = (unsigned long)_1;\n")
	    else
		c_stmt("*poke4_addr = (unsigned long)DBL_PTR(@)->dbl;\n", source)
	    end if
	else
	    c_stmt("*poke4_addr = (unsigned long)@;\n", source)
	end if
    
    else 
	-- DJGPP
	if dbl then
	    c_stmt0("if ((unsigned)poke4_addr > LOW_MEMORY_MAX)\n")
	    c_stmt("*poke4_addr = (unsigned long)DBL_PTR(@)->dbl;\n", source)
	    c_stmt0("else\n")
	    c_stmt("_farpokel(_go32_info_block.selector_for_linear_memory, (unsigned long)poke4_addr, (unsigned long)DBL_PTR(@)->dbl);\n", 
		    source)
	else 
	    c_stmt0("if ((unsigned)poke4_addr > LOW_MEMORY_MAX)\n")
	    c_stmt("*poke4_addr = (unsigned long)@;\n", source)
	    c_stmt0("else\n")
	    c_stmt("_farpokel(_go32_info_block.selector_for_linear_memory, (unsigned long)poke4_addr, (unsigned long)@);\n", 
		    source)
	end if
    end if
end procedure

function machine_func_type(integer x)
-- return the type and min/max when x is an integer constant value
    symtab_index s
    integer func_num
    sequence range
    
    s = x
    
    -- we aren't tracking var (and temp?) constant values in the BB (yet)
    
    if SymTab[s][S_MODE] = M_CONSTANT then
	if GType(x) = TYPE_INTEGER then
	    func_num = ObjValue(x)
	    if func_num != NOVALUE then
		if func_num = M_COMPLETE then 
		    range = {MININT, MAXINT}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_GRAPHICS_MODE then
		    range = {MININT, MAXINT}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_TEXTROWS then
		    range = {20, 500}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_SEEK then
		    range = {MININT, MAXINT}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_LOCK_FILE then
		    range = {0, 1}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_CHDIR then
		    range = {0, 1}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_CHECK_BREAK then
		    range = {0, MAXINT-1000}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_GET_DISPLAY_PAGE then
		    range = {0, 64}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_GET_ACTIVE_PAGE then
		    range = {0, 64}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_ALLOC_LOW then
		    range = {0, 1500000}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_DEFINE_C then
		    range = {-1, 100000000}
		    return {TYPE_INTEGER, range}
		    
		elsif func_num = M_WAIT_KEY then
		    range = {-1, 1000}
		    return {TYPE_INTEGER, range}
		    
		elsif find(func_num, {M_WHERE, M_OPEN_DLL, M_CALLBACK,
				      M_DEFINE_VAR, M_INSTANCE, M_ALLOC,
				      M_F64_TO_A, M_F32_TO_A}) then
		    return {TYPE_ATOM, novalue}
			
		elsif find(func_num, {M_VIDEO_CONFIG, M_GET_POSITION,
				      M_CURRENT_DIR, M_GET_SCREEN_CHAR,
				      M_INTERRUPT, M_GET_VECTOR,
				      M_A_TO_F64, M_A_TO_F32}) then
		    return {TYPE_SEQUENCE, novalue}
			
		else 
		    return {TYPE_OBJECT, novalue}
		    
		end if
	    end if
	end if
    end if
    return {TYPE_OBJECT, novalue}
end function

function machine_func_elem_type(integer x)
-- return the sequence element type when x is an integer constant value
    symtab_index s
    integer func_num
    
    s = x
    
    -- we aren't tracking var (and temp?) constant values in the BB (yet)
    
    if SymTab[s][S_MODE] = M_CONSTANT then
	if GType(x) = TYPE_INTEGER then
	    func_num = ObjValue(x)
	    if func_num != NOVALUE then
		if find(func_num, {M_VIDEO_CONFIG, M_GET_POSITION, 
			M_PALETTE, -- but type itself could be integer
			M_CURRENT_DIR, M_INTERRUPT, M_A_TO_F64, M_A_TO_F32}) then
			return TYPE_INTEGER
		else        
		    return TYPE_OBJECT
		end if
	    end if
	end if
    end if
    return TYPE_OBJECT
end function

procedure main_temps()
-- declare main's temps (for each main_ file)
    symtab_index sp
    
    NewBB(0, E_ALL_EFFECT, 0)
    sp = SymTab[TopLevelSub][S_TEMPS]
    while sp != 0 do
	if SymTab[sp][S_SCOPE] != DELETED then
	    if temp_name_type[SymTab[sp][S_TEMP_NAME]][T_GTYPE] != TYPE_NULL then
		c_stmt0("int ")
		c_printf("_%d", SymTab[sp][S_TEMP_NAME])
		if temp_name_type[SymTab[sp][S_TEMP_NAME]][T_GTYPE] != TYPE_INTEGER then
		    c_puts(" = 0")
		    -- avoids DeRef in 1st BB, but may hurt global type:
		    target = {0, 0}
		    SetBBType(sp, TYPE_INTEGER, target, TYPE_OBJECT)
		end if
		c_puts(";\n")
	    end if
	end if
	SymTab[sp][S_GTYPE] = TYPE_OBJECT
	sp = SymTab[sp][S_NEXT]
    end while
    if SymTab[TopLevelSub][S_LHS_SUBS2] then
	c_stmt0("int _0, _1, _2, _3;\n\n")
    else    
	c_stmt0("int _0, _1, _2;\n\n")
    end if
end procedure

function FoldInteger(integer op, integer target, integer left, integer right)
-- try to fold an integer operation: + - * power floor_div
-- we know that left and right are of type integer.
-- we compute the min/max range of the result (if integer)
    sequence left_val, right_val, result
    atom intres
    atom d1, d2, d3, d4
    object p1, p2, p3, p4
    
    left_val = ObjMinMax(left)
    right_val = ObjMinMax(right)
    result = {NOVALUE, NOVALUE}
    
    if op = PLUS or op = PLUS_I then
	intres = left_val[MIN] + right_val[MIN]
	
	if intres >= MININT and intres <= MAXINT then
	    result[MIN] = intres
	else    
	    result[MIN] = NOVALUE
	end if
	
	intres = left_val[MAX] + right_val[MAX]
	
	if intres >= MININT and intres <= MAXINT then
	    result[MAX] = intres
	else    
	    result[MIN] = NOVALUE
	end if  
	
	if result[MIN] = result[MAX] and result[MIN] != NOVALUE then
	    c_stmt("@ = ", target)
	    c_printf("%d;\n", result[MIN])
	end if
    
    elsif op = MINUS or op = MINUS_I then
	
	intres = left_val[MIN] - right_val[MAX]
	
	if intres >= MININT and intres <= MAXINT then
	    result[MIN] = intres
	else
	    result[MIN] = NOVALUE
	end if
	
	intres = left_val[MAX] - right_val[MIN]
	
	if intres >= MININT and intres <= MAXINT then
	    result[MAX] = intres
	else
	    result[MIN] = NOVALUE
	end if
	
	if result[MIN] = result[MAX] and result[MIN] != NOVALUE then
	    c_stmt("@ = ", target)
	    c_printf("%d;\n", result[MIN])
	end if
    
    elsif op = MULTIPLY then
	
	d1 = left_val[MIN] * right_val[MIN]
	d2 = left_val[MIN] * right_val[MAX]
	d3 = left_val[MAX] * right_val[MIN]
	d4 = left_val[MAX] * right_val[MAX]
	
	if d1 <= MAXINT_DBL and d1 >= MININT_DBL and
	   d2 <= MAXINT_DBL and d2 >= MININT_DBL and
	   d3 <= MAXINT_DBL and d3 >= MININT_DBL and
	   d4 <= MAXINT_DBL and d4 >= MININT_DBL then
	    
	    p1 = d1
	    p2 = d2
	    p3 = d3
	    p4 = d4
	    
	    result[MIN] = p1
	    
	    if p2 < result[MIN] then
		result[MIN] = p2
	    end if
	    
	    if p3 < result[MIN] then
		result[MIN] = p3
	    end if
	    
	    if p4 < result[MIN] then
		result[MIN] = p4
	    end if
	    
	    result[MAX] = p1
	    
	    if p2 > result[MAX] then
		result[MAX] = p2
	    end if
	    
	    if p3 > result[MAX] then
		result[MAX] = p3
	    end if
	    
	    if p4 > result[MAX] then
		result[MAX] = p4
	    end if
	    
	    if result[MIN] = result[MAX] and result[MIN] != NOVALUE then
		intres = result[MIN]
		c_stmt("@ = ", target)
		c_printf("%d;\n", intres)
	    end if
	end if
    
    elsif op = POWER then
	-- be careful - we could cause "overflow" error in power()
	if left_val[MIN] = left_val[MAX] and
	   right_val[MIN] = right_val[MAX] then
	    -- try it 
	    p1 = power(left_val[MIN], right_val[MIN])
	    
	    if integer(p1) then
		result[MIN] = p1
		result[MAX] = result[MIN]
		c_stmt("@ = ", target)
		c_printf("%d;\n", result[MIN])
	    end if
	
	else 
	    -- range of values - crude estimate 
	    -- note: power(x,2) is changed to multiply in emit.c 
	    -- so we try to handle powers up to 4 
	    if right_val[MAX] <= 4 and right_val[MIN] >= 0 and
		left_val[MAX] < 177 and left_val[MIN] > -177 then
		-- should get integer result 
		result[MIN] = MININT
		result[MAX] = MAXINT
	    end if
	
	end if
    
    else 
	-- L_FLOOR_DIV */
	
	-- watch out for MININT / -1 */
	
	if left_val[MIN] = left_val[MAX] and
	   right_val[MIN] = right_val[MAX] and right_val[MIN] != 0 then
	    -- try to constant fold 
--          if right_val[MIN] > 0 and left_val[MIN] >= 0 then
--              intres = left_val[MIN] / right_val[MIN]
--          else 
		intres = floor(left_val[MIN] / right_val[MIN])
--          end if
	    
	    if intres >= MININT and intres <= MAXINT then
		c_stmt("@ = ", target)
		c_printf("%d;\n", intres)
		result[MIN] = intres
		result[MAX] = result[MIN]
	    end if

	else 
	    -- a rough stab at it - could do better */
	    if right_val[MIN] >= 2 then
		-- narrow the result range */
		result[MIN] = left_val[MIN] / right_val[MIN] - 1
		result[MAX] = left_val[MAX] / right_val[MIN] + 1
	    end if
	end if
    end if
    return result
end function

constant DEREF_PACK = 5
sequence deref_buff
deref_buff = {}

procedure FlushDeRef()
    for i = 1 to length(deref_buff) do 
	LeftSym = TRUE
	c_stmt("DeRef(@);\n", deref_buff[i])
    end for
    deref_buff = {}
end procedure

procedure FinalDeRef(symtab_index sym)
-- do final deref of a temp at end of a function, type or procedure
    integer i, t

    i = BB_temp_type(sym)
    t = BB_temp_elem(sym)
    if i != TYPE_INTEGER and i != TYPE_NULL then
	LeftSym = TRUE
	if i = TYPE_ATOM then
	    deref_buff = append(deref_buff, sym)

	elsif i = TYPE_OBJECT then
	    if t = TYPE_INTEGER then
		c_stmt("DeRefi(@);\n", sym)
	    else 
		deref_buff = append(deref_buff, sym)
	    end if

	elsif i = TYPE_SEQUENCE then
	    if t = TYPE_INTEGER then
		c_stmt("DeRefDSi(@);\n", sym)
	    else
		c_stmt("DeRefDS(@);\n", sym)
	    end if

	else 
	    -- TYPE_DOUBLE
	    c_stmt("DeRefDS(@);\n", sym)
	end if
	
	-- try to bundle sets of 5 DeRef's
	if length(deref_buff) = DEREF_PACK then
	    LeftSym = TRUE
	    c_stmt("DeRef5(@", deref_buff[1])
	    for d = 2 to DEREF_PACK do
		c_puts(", ")
		LeftSym = TRUE
		CName(deref_buff[d])
	    end for 
	    c_puts(");\n") 
	    deref_buff = {}
	end if
    end if
end procedure

function NotInRange(integer x, integer badval)
-- return TRUE if x can't be badval 
    sequence range
    
    range = ObjMinMax(x)
    if range[MIN] > badval then
	return TRUE
    end if
    if range[MAX] < badval then
	return TRUE
    end if
    return FALSE
end function

function IntegerMultiply(integer a, integer b)
-- create the optimal code for multiplying two integers,
-- based on their min and max values. 
-- a must be from -INT16 to +INT16
-- b must be from -INT15 to +INT15 
    sequence multiply_code
    sequence dblcode, test_a, test_b1, test_b2
    sequence range_a, range_b
    
    if TypeIs(a, TYPE_INTEGER) then
	range_a = ObjMinMax(a)
    else 
	range_a = {MININT, MAXINT}
    end if
    
    if TypeIs(b, TYPE_INTEGER) then
	range_b = ObjMinMax(b)
    else 
	range_b = {MININT, MAXINT}
    end if
    
    dblcode = "@1 = NewDouble(@2 * (double)@3);\n"
    
    -- test_a 
    if range_a[MIN] >= -INT16 and range_a[MAX] <= INT16 then
	test_a = ""     -- will pass for sure
    
    elsif range_a[MAX] < -INT16 or range_a[MIN] > INT16 then    
	return dblcode  -- will fail for sure
	
    else
	test_a = "@2 == (short)@2"  -- not sure
    
    end if
    
    -- test_b1
    if range_b[MAX] <= INT15 then
	test_b1 = ""    -- will pass for sure
    
    elsif range_b[MIN] > INT15 then
	return dblcode  -- will fail for sure
    
    else
	test_b1 = "@3 <= INT15"  -- not sure
    
    end if
    
    -- test_b2 
    if range_b[MIN] >= -INT15 then
	test_b2 = ""    -- will pass for sure
    
    elsif range_b[MAX] < -INT15 then
	return dblcode  -- will fail for sure
    
    else
	test_b2 = "@3 >= -INT15"  -- not sure
    end if
    
    -- put it all together 
    multiply_code = "if ("
    
    multiply_code &= test_a
    
    if length(test_a) and length(test_b1) then 
	multiply_code &= " && "
    end if
    
    multiply_code &= test_b1
    
    if (length(test_a) or length(test_b1)) and length(test_b2) then 
	multiply_code &= " && " 
    end if
    
    multiply_code &= test_b2
    
    if length(test_a) or length(test_b1) or length(test_b2) then
	multiply_code &= ")\n" &
			 "@1 = @2 * @3;\n" &   
			 "else\n" &
			 "@1 = NewDouble(@2 * (double)@3);\n"
    else 
	multiply_code = "@1 = @2 * @3;\n"  -- no tests, must be integer
    end if
    
    return multiply_code
end function

procedure unary_div(integer pc, integer target_type, sequence intcode,
		    sequence gencode)
-- unary divide ops
    CSaveStr("_0", Code[pc+3], Code[pc+1], 0, 0)
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
    end if
    
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	-- handle integer
	c_stmt(intcode, {Code[pc+3], Code[pc+1]})
    end if
    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    end if
    
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	-- handle double or sequence 
	c_stmt(gencode, {Code[pc+3], Code[pc+1]})
    end if   
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
    end if
		
    CDeRefStr("_0")
    SetBBType(Code[pc+3], target_type, novalue, TYPE_OBJECT)
end procedure 

without warning  -- lots of short-circuit warnings

function unary_optimize(integer pc, integer target_type, sequence target_val,
			sequence intcode, sequence intcode2, sequence gencode)
-- handle a few special unary ops            
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
    end if
    
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	-- handle integer
	if Code[pc] = UMINUS then
	    if (target_type = TYPE_INTEGER or 
	       SymTab[Code[pc+2]][S_GTYPE] = TYPE_INTEGER) and
	       TypeIs(Code[pc+1], TYPE_INTEGER) then
		c_stmt(intcode2, {Code[pc+2], Code[pc+1]})
		CDeRefStr("_0")
		SetBBType(Code[pc+2], TYPE_INTEGER, target_val, TYPE_OBJECT)
		pc += 3
		if Code[pc] = INTEGER_CHECK then
		    pc += 2 -- skip it
		end if
		return pc
	    end if
	end if
	c_stmt(intcode, {Code[pc+2], Code[pc+1]})
    end if
    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    end if
    
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	-- handle double or sequence
	c_stmt(gencode, {Code[pc+2], Code[pc+1]})
    end if   
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
    end if
		
    CDeRefStr("_0")
    SetBBType(Code[pc+2], target_type, target_val, TYPE_OBJECT)
    return pc + 3
end function

function ifwi(integer pc, sequence op)
-- relational ops, integer operands 
    atom result
    sequence left_val, right_val
    
    result = NOVALUE
    left_val = ObjMinMax(Code[pc+1])
    right_val = ObjMinMax(Code[pc+2])
    
    if equal(op, ">=") then
	if left_val[MIN] >= right_val[MAX] then
	    result = TRUE
	elsif left_val[MAX] < right_val[MIN] then
	    result = FALSE
	end if
    
    elsif equal(op, "<=") then
	if left_val[MAX] <= right_val[MIN] then
	    result = TRUE
	elsif left_val[MIN] > right_val[MAX] then
	    result = FALSE
	end if
    
    elsif equal(op, "!=") then
	if left_val[MAX] < right_val[MIN] then
	    result = TRUE
	elsif left_val[MIN] > right_val[MAX] then
	    result = TRUE
	elsif left_val[MAX] = left_val[MIN] and 
	      right_val[MAX] = right_val[MIN] and 
	      left_val[MIN] = right_val[MIN] then
	    result = FALSE
	end if
    
    elsif equal(op, "==") then
	if left_val[MAX] < right_val[MIN] then
	    result = FALSE
	elsif left_val[MIN] > right_val[MAX] then
	    result = FALSE
	elsif left_val[MAX] = left_val[MIN] and 
	      right_val[MAX] = right_val[MIN] and 
	      left_val[MIN] = right_val[MIN] then
	    result = TRUE
	end if
    
    elsif equal(op, ">") then
	if left_val[MIN] > right_val[MAX] then
	    result = TRUE
	elsif left_val[MAX] <= right_val[MIN] then
	    result = FALSE
	end if
    
    elsif equal(op, "<") then
	if left_val[MAX] < right_val[MIN] then
	    result = TRUE
	elsif left_val[MIN] >= right_val[MAX] then
	    result = FALSE
	end if
	    
    end if
    
    if result = TRUE then
	-- skip the entire IF statement_list END IF
	return Code[pc+3]
    
    elsif result = NOVALUE then
	c_stmt("if (@ " & op & " @)\n", {Code[pc+1], Code[pc+2]})
	Goto(Code[pc+3])
	return pc + 4
    
    else
	return pc + 4
    end if
end function

function ifw(integer pc, sequence op, sequence intop)
-- relational ops, integers or atoms
    -- could be better optimized
    if TypeIs(Code[pc+1], TYPE_INTEGER) and 
       TypeIs(Code[pc+2], TYPE_INTEGER) then
--      c_stmt("if (@ ", Code[pc+1])
--      c_puts(intop)
--      temp_indent = -indent
--      c_stmt(" @)\n", Code[pc+2])   -- leading blank to avoid LeftSym
	return ifwi(pc, intop)
    else 
	c_stmt0("if (binary_op_a(")
	c_puts(op)
	temp_indent = -indent
	c_stmt(", @, @))\n", {Code[pc+1], Code[pc+2]})
    end if
    temp_indent = 4
    Goto(Code[pc+3])
    return pc + 4
end function

function binary_op(integer pc, integer iii, sequence target_val, 
		   sequence intcode, sequence intcode2, sequence intcode_extra,
		   sequence gencode, sequence dblfn, integer atom_type)
-- handle the completion of many binary ops
    integer target_elem, target_type, np, check
    boolean close_brace
    
    target_elem = TYPE_OBJECT
		
    if TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	target_type = TYPE_SEQUENCE
	if iii and 
	    SeqElem(Code[pc+1]) = TYPE_INTEGER and
	    (TypeIs(Code[pc+2], TYPE_INTEGER) or
	    (TypeIs(Code[pc+2], TYPE_SEQUENCE) and 
	    SeqElem(Code[pc+2]) = TYPE_INTEGER)) then
	    target_elem = TYPE_INTEGER
	end if

    elsif TypeIs(Code[pc+2], TYPE_SEQUENCE) then
	target_type = TYPE_SEQUENCE
	if iii and 
	      SeqElem(Code[pc+2]) = TYPE_INTEGER and
	      TypeIs(Code[pc+1], TYPE_INTEGER) then
	    target_elem = TYPE_INTEGER
	end if

    elsif TypeIs(Code[pc+1], TYPE_OBJECT) then
	target_type = TYPE_OBJECT
		
    elsif TypeIs(Code[pc+2], TYPE_OBJECT) then
	target_type = TYPE_OBJECT
		
    else 
	target_type = atom_type
		
    end if
		
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
		
    close_brace = FALSE
		
    check = 0
		
    if TypeIs(Code[pc+1], TYPE_INTEGER) and 
       TypeIs(Code[pc+2], TYPE_INTEGER) then
	-- uncertain about neither
		    
	if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I,
			   MULTIPLY, FLOOR_DIV, POWER}) then

	    np = pc + 4 + 2 * (Code[pc+4] = INTEGER_CHECK)
	    target = FoldInteger(Code[pc], Code[pc+3], Code[pc+1], Code[pc+2])
	    if target[MIN] != NOVALUE and 
	       target[MIN] = target[MAX] then 
		-- constant folding code was emitted
		CDeRefStr("_0")
		SetBBType(Code[pc+3], TYPE_INTEGER, target, 
				      TYPE_OBJECT)
		return np

	    elsif SymTab[Code[pc+3]][S_GTYPE] = TYPE_INTEGER or 
		  IntegerSize(np, Code[pc+3]) or
		  target[MIN] != NOVALUE then
		-- result will be an integer
		c_stmt(intcode2, {Code[pc+3], Code[pc+1], Code[pc+2]})
		CDeRefStr("_0")
		if target[MIN] = NOVALUE then
		    target = novalue
		end if
		SetBBType(Code[pc+3], TYPE_INTEGER, target, TYPE_OBJECT)
		return np 
	    end if
	end if
		    
	c_stmt(intcode, {Code[pc+3], Code[pc+1], Code[pc+2]})
		    
	if iii then
	    -- int operands => int result
	    SetBBType(Code[pc+3], TYPE_INTEGER, target_val, TYPE_OBJECT)
	else 
	    SetBBType(Code[pc+3], TYPE_ATOM, novalue, TYPE_OBJECT)
	end if
		    
	-- now that Code[pc+3]'s type and value have been updated:
	if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I}) then
	    c_stmt(intcode_extra, {Code[pc+3], Code[pc+1], Code[pc+2]})
	end if
			
	CDeRefStr("_0")
		    
	return pc + 4
		
    elsif TypeIs(Code[pc+2], TYPE_INTEGER) and 
	  TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	-- uncertain about Code[pc+1] only 
	check = 1
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
		    
	if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I,
			   MULTIPLY, FLOOR_DIV}) and 
		(SymTab[Code[pc+3]][S_GTYPE] = TYPE_INTEGER or
		    IntegerSize(pc+4, Code[pc+3])) then
	    c_stmt(intcode2, {Code[pc+3], Code[pc+1], Code[pc+2]})
		    
	else 
	    c_stmt(intcode, {Code[pc+3], Code[pc+1], Code[pc+2]})
	    if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I}) then
		SetBBType(Code[pc+3], GType(Code[pc+3]), target_val, target_elem)
		-- now that Code[pc+3]'s value has been updated:
		c_stmt(intcode_extra, {Code[pc+3], Code[pc+1], Code[pc+2]})
	    end if
		    
	end if
		    
	c_stmt0("}\n")
	c_stmt0("else {\n")
	close_brace = TRUE
		
    elsif TypeIs(Code[pc+1], TYPE_INTEGER) and
	  TypeIs(Code[pc+2], {TYPE_ATOM, TYPE_OBJECT}) then
	-- uncertain about Code[pc+2] only 
	check = 2
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+2])
		    
	if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I,
			   MULTIPLY, FLOOR_DIV}) and
			(SymTab[Code[pc+3]][S_GTYPE] = TYPE_INTEGER or
			 IntegerSize(pc+4, Code[pc+3])) then
	    c_stmt(intcode2, {Code[pc+3], Code[pc+1], Code[pc+2]})
	else 
	    c_stmt(intcode, {Code[pc+3], Code[pc+1], Code[pc+2]})
	    if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I}) then
		SetBBType(Code[pc+3], GType(Code[pc+3]), 
				      target_val, target_elem)
		-- now that Code[pc+3]'s value has been updated:
		c_stmt(intcode_extra, {Code[pc+3], Code[pc+1], Code[pc+2]})
	    end if
	end if
	c_stmt0("}\n")
	c_stmt0("else {\n")
	close_brace = TRUE
		
    elsif TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) and
	  TypeIs(Code[pc+2], {TYPE_ATOM, TYPE_OBJECT}) then
	-- uncertain about both types being TYPE_INTEGER or not 
	c_stmt("if (IS_ATOM_INT(@) && IS_ATOM_INT(@)) {\n", {Code[pc+1], Code[pc+2]})
		    
	if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I,
			   MULTIPLY, FLOOR_DIV}) and
			(SymTab[Code[pc+3]][S_GTYPE] = TYPE_INTEGER or
			 IntegerSize(pc+4, Code[pc+3])) then
	    c_stmt(intcode2, {Code[pc+3], Code[pc+1], Code[pc+2]})
		    
	else 
	    c_stmt(intcode, {Code[pc+3], Code[pc+1], Code[pc+2]})
	    if find(Code[pc], {PLUS, PLUS_I, MINUS, MINUS_I}) then
		SetBBType(Code[pc+3], GType(Code[pc+3]), target_val, target_elem)
		-- now that Code[pc+3]'s value has been updated:
		c_stmt(intcode_extra, {Code[pc+3], Code[pc+1], Code[pc+2]})
	    end if
	end if
	c_stmt0("}\n")
	c_stmt0("else {\n")
	close_brace = TRUE
    end if

    if TypeIsNot(Code[pc+1], TYPE_INTEGER) or 
       TypeIsNot(Code[pc+2], TYPE_INTEGER) then
	if Code[pc] != FLOOR_DIV and
	   TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
	   TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	    -- both are known to be atoms and integer:integer
	    -- possibility has been handled - do it in-line 
			
	    if check != 1 and 
	       TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
		c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
	    end if
			
	    if check != 1 and 
	       TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
		if length(dblfn) > 2 then
		    c_stmt("temp_d.dbl = (double)@;\n", Code[pc+1])
		    c_stmt("@ = ", Code[pc+3])
		    c_puts(dblfn)
		    temp_indent = -indent
		    c_stmt("(&temp_d, DBL_PTR(@));\n", Code[pc+2])
		else 
		    c_stmt("@ = ", Code[pc+3])
		    temp_indent = -indent
		    if atom_type = TYPE_INTEGER then
			c_stmt("((double)@ ", Code[pc+1])
		    else
			c_stmt("NewDouble((double)@ ", Code[pc+1])
		    end if
		    c_puts(dblfn)
		    temp_indent = -indent
		    c_stmt(" DBL_PTR(@)->dbl);\n", Code[pc+2])
		end if
	    end if
			
	    if check != 1 and
	       TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
		c_stmt0("}\n")
		c_stmt0("else {\n")
	    end if
			
	    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
		if check != 2 and
		   TypeIs(Code[pc+2], {TYPE_ATOM, TYPE_OBJECT}) then
		    c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+2])
		end if
			    
		if check != 2 and 
		   TypeIs(Code[pc+2], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
		    if length(dblfn) > 2 then
			c_stmt("temp_d.dbl = (double)@;\n", Code[pc+2])
			c_stmt("@ = ", Code[pc+3])
			c_puts(dblfn)
			temp_indent = -indent
			c_stmt("(DBL_PTR(@), &temp_d);\n", Code[pc+1])
		    else 
			c_stmt("@ = ", Code[pc+3])
			temp_indent = -indent
			if atom_type = TYPE_INTEGER then
			    c_stmt("(DBL_PTR(@)->dbl ", Code[pc+1])
			else
			    c_stmt("NewDouble(DBL_PTR(@)->dbl ", Code[pc+1])
			end if  
			c_puts(dblfn)
			temp_indent = -indent
			c_stmt(" (double)@);\n", Code[pc+2])
		    end if
		end if
			
		if check != 2 and 
		   TypeIs(Code[pc+2], {TYPE_ATOM, TYPE_OBJECT}) then
		    c_stmt0("}\n")
		    c_stmt0("else\n")
		end if
			    
		if TypeIsNot(Code[pc+2], TYPE_INTEGER) then
		    if length(dblfn) > 2 then
			c_stmt("@ = ", Code[pc+3])
			c_puts(dblfn)
			temp_indent = -indent
			c_stmt("(DBL_PTR(@), DBL_PTR(@));\n", 
					    {Code[pc+1], Code[pc+2]})
		    else 
			c_stmt("@ = ", Code[pc+3])
			temp_indent = -indent
			if atom_type = TYPE_INTEGER then
			    c_stmt("(DBL_PTR(@)->dbl ", Code[pc+1])
			else
			    c_stmt("NewDouble(DBL_PTR(@)->dbl ", Code[pc+1])
			end if
			c_puts(dblfn)
			temp_indent = -indent
			c_stmt(" DBL_PTR(@)->dbl);\n", Code[pc+2])
		    end if
		end if
	    end if
	    
	    if check != 1 and 
	       TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
		c_stmt0("}\n")
	    end if
		    
	else 
	    -- one might be a sequence - use general call
	    c_stmt(gencode, {Code[pc+3], Code[pc+1], Code[pc+2]})
		    
	end if
    end if

    if close_brace then
	c_stmt0("}\n")
    end if
		
    CDeRefStr("_0")
    SetBBType(Code[pc+3], target_type, target_val, target_elem)
    return pc + 4
end function

integer previous_previous_op
previous_previous_op = 0
integer previous_op
previous_op = 0
integer opcode
opcode = 0

procedure arg_list(integer i)
-- list of arguments for CALL_PROC / CALL_FUNC  
    indent += 20
    for k = 1 to i do
	c_stmt0("*(int *)(_2+")
	c_printf("%d)", k * 4)
	if k != i then
	    c_puts(", ")
	end if
	c_puts("\n")
    end for
    c_stmt0(" );\n")
    indent -= 20
end procedure

-- common vars for do_exec ops
integer iii, n, t, close_brace, doref, ov
atom len, j
sequence inc, range1, range2, x
integer const_subs, check
symtab_index sub, sym, p
sequence gencode, intcode, intcode_extra, intcode2, op, intop
sequence main_name
integer target_type, target_elem, atom_type
sequence target_val
integer np, pc
sequence dblfn
boolean all_done

procedure opSTARTLINE()
-- common in Translator, not in Interpreter
    sequence line
    integer offset
    
    c_putc('\n')
    offset = slist[Code[pc+1]][SRC]
    line = fetch_line(offset)
    if trace_called and 
       and_bits(slist[Code[pc+1]][OPTIONS], SOP_TRACE) then
	c_stmt0("ctrace(\"")
	c_puts(name_ext(file_name[slist[Code[pc+1]][LOCAL_FILE_NO]]))
	c_printf(":%d\t", slist[Code[pc+1]][LINE])
	c_fixquote(line)
	c_puts("\");\n")
		
    else 
	c_stmt0("// ")
	for i = length(line) to 1 by -1 do
	    if not find(line[i], " \t\r\n") then
		if line[i] = '\\' then
		    -- \ char at end of line causes line continuation in C
		    line &= " --"
		end if
		exit
	    end if
	end for
	c_puts(line)
	c_puts("\n")
    end if
    pc += 2
end procedure

procedure opPROC()  
-- Normal subroutine call
-- generate code for a procedure/function call  
    symtab_index sub
    integer n, t, p
	    
    sub = Code[pc+1]
    
    n = 2 + SymTab[sub][S_NUM_ARGS] + (SymTab[sub][S_TOKEN] != PROC)

    -- update argument types
    p = SymTab[sub][S_NEXT]
    for i = 1 to SymTab[sub][S_NUM_ARGS] do
	t = Code[pc+1+i]
	CRef(t)
	SymTab[t][S_ONE_REF] = FALSE
	SymTab[p][S_ARG_TYPE_NEW] = or_type(SymTab[p][S_ARG_TYPE_NEW], GType(t))
		    
	if TypeIs(t, {TYPE_SEQUENCE, TYPE_OBJECT}) then
	    SymTab[p][S_ARG_MIN_NEW] = NOVALUE
	    SymTab[p][S_ARG_SEQ_ELEM_NEW] = 
				or_type(SymTab[p][S_ARG_SEQ_ELEM_NEW], SeqElem(t))
	    if SymTab[p][S_ARG_SEQ_LEN_NEW] = -NOVALUE then
		SymTab[p][S_ARG_SEQ_LEN_NEW] = SeqLen(t)
	    elsif SymTab[p][S_ARG_SEQ_LEN_NEW] != SeqLen(t) then
		SymTab[p][S_ARG_SEQ_LEN_NEW] = NOVALUE
	    end if
		    
	elsif TypeIs(t, TYPE_INTEGER) then
	    target = ObjMinMax(t)
	    if SymTab[p][S_ARG_MIN_NEW] = -NOVALUE then
		-- first value in this pass
		SymTab[p][S_ARG_MIN_NEW] = target[MIN]
		SymTab[p][S_ARG_MAX_NEW] = target[MAX]
		    
	    elsif SymTab[p][S_ARG_MIN_NEW] != NOVALUE then
		-- widen the range
		if target[MIN] < SymTab[p][S_ARG_MIN_NEW] then
		    SymTab[p][S_ARG_MIN_NEW] = target[MIN]
		end if
		if target[MAX] > SymTab[p][S_ARG_MAX_NEW] then
		    SymTab[p][S_ARG_MAX_NEW] = target[MAX]
		end if
	    end if
		    
	else 
	    SymTab[p][S_ARG_MIN_NEW] = NOVALUE
		
	end if
		    
	p = SymTab[p][S_NEXT]
    end for

    if SymTab[sub][S_TOKEN] != PROC then
	p = Code[pc+n-1]
	if SymTab[p][S_MODE] = M_NORMAL and (SymTab[p][S_SCOPE] = SC_GLOBAL or
	   SymTab[p][S_SCOPE] = SC_LOCAL) then
	    -- global/local might be modified during the call,
	    -- so complete the call before setting DeRef value
	    c_stmt("_0 = ", p)
	else 
	    CSaveStr("_0", p, p, 0, 0)
	    c_stmt("@ = ", p)
	end if
	temp_indent = -indent
    end if
    LeftSym = TRUE
    c_stmt("@", sub)
    c_puts("(")
    for i = 1 to SymTab[sub][S_NUM_ARGS] do
	CName(Code[pc+1+i])
	if i != SymTab[sub][S_NUM_ARGS] then
	    c_puts(", ")
	end if
    end for
    c_puts(");\n")

    if SymTab[sub][S_EFFECT] then
	NewBB(1, SymTab[sub][S_EFFECT], sub) -- forget some local & global var values 
    end if
		
    if SymTab[sub][S_TOKEN] != PROC then
	if SymTab[p][S_MODE] = M_NORMAL and
	    (SymTab[p][S_SCOPE] = SC_GLOBAL or
		SymTab[p][S_SCOPE] = SC_LOCAL) then
	    CDeRef(p)  -- DeRef latest value, not old one
	    c_stmt("@ = _0;\n", p)
	else 
	    CDeRefStr("_0")
	end if
		
	if SymTab[sub][S_GTYPE] = TYPE_INTEGER then
	    target = {SymTab[sub][S_OBJ_MIN], SymTab[sub][S_OBJ_MAX]}
	    SetBBType(Code[pc+n-1], SymTab[sub][S_GTYPE], target, TYPE_OBJECT)
		
	elsif SymTab[sub][S_GTYPE] = TYPE_SEQUENCE then
	    target[MIN] = SymTab[sub][S_SEQ_LEN]
	    SetBBType(Code[pc+n-1], SymTab[sub][S_GTYPE], target, 
			      SymTab[sub][S_SEQ_ELEM])
		
	else 
	    SetBBType(Code[pc+n-1], SymTab[sub][S_GTYPE], novalue, 
			      SymTab[sub][S_SEQ_ELEM])
		
	end if
	SymTab[Code[pc+n-1]][S_ONE_REF] = FALSE
    end if
    pc += n
end procedure

procedure opRHS_SUBS()
-- RHS_SUBS / RHS_SUBS_CHECK / RHS_SUBS_I / ASSIGN_SUBS / PASSIGN_SUBS
-- var[subs] op= expr 
-- generate code for right-hand-side subscripting
-- pc+1 (or _3 from above) is the sequence
-- pc+2 is the subscript
-- pc+3 is the target
    
    CSaveStr("_0", Code[pc+3], Code[pc+2], Code[pc+1], 0)
    SymTab[Code[pc+3]][S_ONE_REF] = FALSE
		
    if Code[pc] = ASSIGN_OP_SUBS or Code[pc] = PASSIGN_OP_SUBS then
	if Code[pc] = PASSIGN_OP_SUBS then
	    c_stmt0("_2 = (int)SEQ_PTR(*(int *)_3);\n")
	else 
	    c_stmt("_2 = (int)SEQ_PTR(@);\n", Code[pc+1])
	    -- element type of pc[1] is changed
	    SetBBType(Code[pc+1], TYPE_SEQUENCE, novalue, TYPE_OBJECT)
	end if
    else
	c_stmt("_2 = (int)SEQ_PTR(@);\n", Code[pc+1])
    end if  
	    
    -- _2 has the sequence
		
    if TypeIsNot(Code[pc+2], TYPE_INTEGER) then
	c_stmt("if (!IS_ATOM_INT(@))\n", Code[pc+2])
	c_stmt("@ = (int)*(((s1_ptr)_2)->base + (int)(DBL_PTR(@)->dbl));\n", 
		{Code[pc+3], Code[pc+2]})
	c_stmt0("else\n")
    end if
    c_stmt("@ = (int)*(((s1_ptr)_2)->base + @);\n", {Code[pc+3], Code[pc+2]})
		
    if Code[pc] = PASSIGN_OP_SUBS then -- simplified
	LeftSym = TRUE
	c_stmt("Ref(@);\n", Code[pc+3])
	CDeRefStr("_0")
	SetBBType(Code[pc+3], 
			 TYPE_OBJECT,    -- we don't know the element type
			 novalue, TYPE_OBJECT)
    else 
	if Code[pc] = RHS_SUBS_I then
	    -- target is integer var - convert doubles to ints
	    if SeqElem(Code[pc+1]) != TYPE_INTEGER then
		SetBBType(Code[pc+3], TYPE_OBJECT, novalue, TYPE_OBJECT)
		c_stmt("if (!IS_ATOM_INT(@))\n", Code[pc+3])
		c_stmt("@ = (long)DBL_PTR(@)->dbl;\n", {Code[pc+3], Code[pc+3]})
	    end if
	    CDeRefStr("_0")
	    SetBBType(Code[pc+3], TYPE_INTEGER, novalue, TYPE_OBJECT)
		    
	elsif Code[pc+4] = INTEGER_CHECK then
	    -- INTEGER_CHECK coming next 
	    if SeqElem(Code[pc+1]) != TYPE_INTEGER then
		SetBBType(Code[pc+3], TYPE_OBJECT, novalue, TYPE_OBJECT)
		c_stmt("if (!IS_ATOM_INT(@))\n", Code[pc+3])
		c_stmt("@ = (long)DBL_PTR(@)->dbl;\n", {Code[pc+3], Code[pc+3]})
	    end if
	    CDeRefStr("_0")
	    SetBBType(Code[pc+3], TYPE_INTEGER, novalue, TYPE_OBJECT)
	    pc += 2 -- skip INTEGER_CHECK 
		    
	else 
	    if SeqElem(Code[pc+1]) != TYPE_INTEGER then
		LeftSym = TRUE
		if SeqElem(Code[pc+1]) = TYPE_OBJECT or
		   SeqElem(Code[pc+1]) = TYPE_ATOM then
		    c_stmt("Ref(@);\n", Code[pc+3])
		else
		    c_stmt("RefDS(@);\n", Code[pc+3])
		end if
	    end if
	    CDeRefStr("_0")
	    SetBBType(Code[pc+3], SeqElem(Code[pc+1]), novalue, TYPE_OBJECT)
		
	end if               
    end if
    
    pc += 4
end procedure           
	
procedure opNOP1()
-- NOP1 / NOPWHILE
-- no-op - one word in translator, emit a label, not used in interpreter
    if opcode = NOPWHILE then
	in_loop = append(in_loop, 0)
    end if
    Label(pc+1)
    pc += 1
end procedure

procedure opINTERNAL_ERROR()
    InternalErr("This opcode should never be emitted!")
end procedure

procedure opIF()     
-- IF / WHILE           
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	if opcode = WHILE then
	    c_stmt("if (@ <= 0) {\n", Code[pc+1]) -- quick test 
	end if
	c_stmt("if (@ == 0) {\n", Code[pc+1])
	Goto(Code[pc+2])
	c_stmt0("}\n")
	c_stmt0("else {\n")
	c_stmt("if (!IS_ATOM_INT(@) && DBL_PTR(@)->dbl == 0.0)\n", 
			{Code[pc+1], Code[pc+1]})
	Goto(Code[pc+2])
	c_stmt0("}\n")
	if opcode = WHILE then
	    c_stmt0("}\n")
	end if
	pc += 3
	    
    elsif ObjValue(Code[pc+1]) != NOVALUE and
	  ObjValue(Code[pc+1]) != 0 then
	-- non-zero integer  - front-end can optimize this for "while 1"
	-- no code to emit for test
	pc += 3 -- if/while TRUE - skip the test and goto

    elsif ObjValue(Code[pc+1]) = NOVALUE or
	  forward_branch_into(pc+3, Code[pc+2]-1) then
	if ObjValue(Code[pc+1]) != 0 then  -- non-zero handled above
	    c_stmt("if (@ == 0)\n", Code[pc+1])
	end if
	Goto(Code[pc+2])
	pc += 3
		
    else -- it's 0
	pc = Code[pc+2]  -- if/while FALSE - skip the whole block
			 -- (no branch into from short-circuit)
    end if
end procedure               
	    
procedure opINTEGER_CHECK()
-- INTEGER_CHECK    
    if BB_var_type(Code[pc+1]) != TYPE_INTEGER then
	c_stmt("if (!IS_ATOM_INT(@)) {\n", Code[pc+1])
	LeftSym = TRUE
	c_stmt("_1 = (long)(DBL_PTR(@)->dbl);\n", Code[pc+1])
	LeftSym = TRUE
	c_stmt("DeRefDS(@);\n", Code[pc+1])
	c_stmt("@ = _1;\n", Code[pc+1])
	c_stmt0("}\n")
	SetBBType(Code[pc+1], TYPE_INTEGER, novalue, TYPE_OBJECT)
    end if
    pc += 2
end procedure           

procedure opATOM_CHECK()
-- ATOM_CHECK / SEQUENCE_CHECK  
-- other type checks - ignored by compiler */
    pc += 2
end procedure           
	
procedure opASSIGN_SUBS()    
-- Final subscript and assignment 
-- Code[pc+1] has the sequence or temp containing a pointer
-- Code[pc+2] has the subscript
-- Code[pc+3] has the source
		
    const_subs = -1
		
    -- get the subscript */
		
    CRef(Code[pc+3]) -- takes care of ASSIGN_SUBS_I
    SymTab[Code[pc+3]][S_ONE_REF] = FALSE
		
    if Code[pc+1] = Code[pc+3] then
	-- must point to original sequence
	c_stmt("_0 = @;\n", Code[pc+3]) 
    end if  
	    
    -- check for uniqueness
    if opcode = PASSIGN_SUBS then
	-- sequence is pointed-to from a temp
	c_stmt0("_2 = (int)SEQ_PTR(*(int *)_3);\n")
	c_stmt0("if (!UNIQUE(_2)) {\n")
	c_stmt0("_2 = (int)SequenceCopy((s1_ptr)_2);\n")
	c_stmt0("*(int *)_3 = MAKE_SEQ(_2);\n")
	c_stmt0("}\n")
	    
    else 
	c_stmt("_2 = (int)SEQ_PTR(@);\n", Code[pc+1])
		    
	if SymTab[Code[pc+1]][S_ONE_REF] = FALSE then
	    c_stmt0("if (!UNIQUE(_2)) {\n")
	    c_stmt0("_2 = (int)SequenceCopy((s1_ptr)_2);\n")
	    c_stmt("@ = MAKE_SEQ(_2);\n", Code[pc+1])
	    c_stmt0("}\n")
	end if
	    
    end if
		
    if TypeIsNot(Code[pc+2], TYPE_INTEGER) then
	c_stmt("if (!IS_ATOM_INT(@))\n", Code[pc+2])
	c_stmt("_2 = (int)(((s1_ptr)_2)->base + (int)(DBL_PTR(@)->dbl));\n", 
		Code[pc+2])
	c_stmt0("else\n")
    end if
    c_stmt("_2 = (int)(((s1_ptr)_2)->base + @);\n", Code[pc+2])
		
    if opcode = PASSIGN_SUBS then  
	-- or previous_previous_op = ASSIGN_OP_SUBS  ???
		
	-- Do we need to SetBBType in this _3 case????
	-- multiple lhs subs may be ok, but what about
	-- a[i] += expr ?
	-- That could change the element type of a. 
	-- ... we set element type to TYPE_OBJECT 
	-- in ASSIGN_OP_SUBS above
		    
	c_stmt0("_1 = *(int *)_2;\n")
	if Code[pc+1] = Code[pc+3] then
	    c_stmt0("*(int *)_2 = _0;\n")
	else
	    c_stmt("*(int *)_2 = @;\n", Code[pc+3])
	end if  
	c_stmt0("DeRef(_1);\n")
	    
    else 
	if SeqElem(Code[pc+1]) != TYPE_INTEGER then 
	    c_stmt0("_1 = *(int *)_2;\n")
	end if  
		
	if Code[pc+1] = Code[pc+3] then
	    c_stmt0("*(int *)_2 = _0;\n")
	else
	    c_stmt("*(int *)_2 = @;\n", Code[pc+3])
	end if  
		
	if SeqElem(Code[pc+1]) != TYPE_INTEGER then
	    if SeqElem(Code[pc+1]) = TYPE_OBJECT or
	       SeqElem(Code[pc+1]) = TYPE_ATOM then
		c_stmt0("DeRef(_1);\n")
	    else
		c_stmt0("DeRefDS(_1);\n")
	    end if
	end if
	-- we can't say that all element types are GType(Code[pc+3])
	-- at this point, but we must adjust the global view
	-- of the element type. We shouldn't say TYPE_OBJECT either. 
	target[MIN] = -1
	SetBBType(Code[pc+1], TYPE_SEQUENCE, target, GType(Code[pc+3]))
    end if
    pc += 4
end procedure

procedure opLENGTH()
-- LENGTH / PLENGTH
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    if opcode = LENGTH and 
       TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	if SeqLen(Code[pc+1]) != NOVALUE then
	    -- we know the length
	    c_stmt("@ = ", Code[pc+2])
	    c_printf("%d;\n", SeqLen(Code[pc+1]))
	    target = repeat(SeqLen(Code[pc+1]), 2)
	else 
	    c_stmt("@ = SEQ_PTR(@)->length;\n", {Code[pc+2], Code[pc+1]})
	    target = {0, MAXLEN}
	end if
	CDeRefStr("_0")
	SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
    else 
	if opcode = PLENGTH then
	    -- we have a pointer to a sequence
	    c_stmt("@ = SEQ_PTR(*(object_ptr)_3)->length;\n", Code[pc+2])
	else    
	    c_stmt("@ = SEQ_PTR(@)->length;\n", {Code[pc+2], Code[pc+1]})
	end if
	CDeRefStr("_0")
	SetBBType(Code[pc+2], TYPE_INTEGER, novalue, TYPE_OBJECT)
    end if
    pc += 3
end procedure

procedure opASSIGN()
    CRef(Code[pc+1])
    SymTab[Code[pc+1]][S_ONE_REF] = FALSE
    SymTab[Code[pc+2]][S_ONE_REF] = FALSE
    if SymTab[Code[pc+2]][S_MODE] = M_CONSTANT then
	if SymTab[Code[pc+1]][S_MODE] != M_CONSTANT or
	   TypeIsNot(Code[pc+1], TYPE_INTEGER) or
	   not integer(ObjValue(Code[pc+1])) then
	    c_stmt("@ = @;\n", {Code[pc+2], Code[pc+1]})
	else 
	    -- don't have to assign literal integer to a constant
	    -- mark the constant as deleted 
	    SymTab[Code[pc+2]][S_USAGE] = U_DELETED
	end if
	    
    else   
	CDeRef(Code[pc+2])
	c_stmt("@ = @;\n", {Code[pc+2], Code[pc+1]})
    end if
	    
    if TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target[MIN] = SeqLen(Code[pc+1])
	SetBBType(Code[pc+2], GType(Code[pc+1]), target, SeqElem(Code[pc+1]))
    else 
	SetBBType(Code[pc+2], GType(Code[pc+1]), ObjMinMax(Code[pc+1]),
		  TYPE_OBJECT)
    end if
    pc += 3
end procedure

procedure opASSIGN_I()
-- source & destination are known to be integers */
    c_stmt("@ = @;\n", {Code[pc+2], Code[pc+1]})
    SetBBType(Code[pc+2], TYPE_INTEGER, ObjMinMax(Code[pc+1]), TYPE_OBJECT)
    pc += 3
end procedure
		
procedure opEXIT()
-- EXIT / ELSE / ENDWHILE
    if opcode = ENDWHILE then
	in_loop = in_loop[1..length(in_loop)-1]
    end if
    Goto(Code[pc+1])               
    pc += 2
end procedure
	    
procedure opRIGHT_BRACE_N()
-- form a sequence of any length 
    len = Code[pc+1]+2
    if Code[pc+1] = 0 then
	CSaveStr("_0", Code[pc+len], 0, 0, 0) -- no need to delay DeRef
    else
	CSaveStr("_0", Code[pc+len], Code[pc+len], 0, 0) 
	-- must delay DeRef
    end if  
    c_stmt0("_1 = NewS1(")
    c_printf("%d);\n", Code[pc+1])
		
    if Code[pc+1] > 0 then
	c_stmt0("_2 = (int)((s1_ptr)_1)->base;\n")
    end if
	    
    n = 0 -- repeat count
    for i = 1 to Code[pc+1] do
	t = Code[pc+len-i]
	SymTab[t][S_ONE_REF] = FALSE
	if i < Code[pc+1] and t = Code[pc+len-i-1] then
	    n += 1   -- same as the next one
	else 
	    -- not same, or end of list
	    if n <= 6 then
		if n > 0 then
		    CRefn(t, n+1)
		else
		    CRef(t)
		end if
		while n >= 0 do
		    c_stmt0("*((int *)(_2")
		    c_printf("+%d", (i-n)*4)
		    c_puts("))")
		    temp_indent = -indent
		    c_stmt(" = @;\n", t)
		    n -= 1
		end while
	    else 
		-- 8 or more of the same in a row
		c_stmt0("RepeatElem(_2")  -- does Refs too
		temp_indent = -indent
		c_printf("+%d,", (i-n)*4)
		temp_indent = -indent
		c_stmt(" @, ", t)
		c_printf("%d);\n", n+1)
	    end if
	    n = 0
	end if
    end for
    c_stmt("@ = MAKE_SEQ(_1);\n", Code[pc+len])
    CDeRefStr("_0")
    t = TYPE_NULL
    for i = 1 to Code[pc+1] do
	t = or_type(t, GType(Code[pc+len-i]))
    end for
    target[MIN] = Code[pc+1]
    SetBBType(Code[pc+len], TYPE_SEQUENCE, target, t)
    pc += 3 + Code[pc+1]
end procedure

procedure opRIGHT_BRACE_2()
-- form a sequence of length 2
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt0("_1 = NewS1(2);\n")
    c_stmt0("_2 = (int)((s1_ptr)_1)->base;\n")
    c_stmt("((int *)_2)[1] = @;\n", Code[pc+2])
    CRef(Code[pc+2])
    SymTab[Code[pc+2]][S_ONE_REF] = FALSE
    c_stmt("((int *)_2)[2] = @;\n", Code[pc+1])
    CRef(Code[pc+1])
    SymTab[Code[pc+1]][S_ONE_REF] = FALSE
    c_stmt("@ = MAKE_SEQ(_1);\n", Code[pc+3])
    CDeRefStr("_0")
    target[MIN] = 2
    SetBBType(Code[pc+3], TYPE_SEQUENCE, target, 
	      or_type(GType(Code[pc+1]), GType(Code[pc+2])))
    pc += 4
end procedure

procedure opPLUS1()
-- PLUS1 / PLUS1_I
    CSaveStr("_0", Code[pc+3], Code[pc+1], 0, 0)
		
    target_type = GType(Code[pc+1])
    if target_type = TYPE_INTEGER then
	target_type = TYPE_ATOM
    end if
		    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then 
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])              
    end if
		
    np = pc + 4
    target_val = novalue
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	if TypeIs(Code[pc+1], TYPE_INTEGER) then 
	    target_val = ObjMinMax(Code[pc+1])
	end if
	ov = TRUE
	np = pc + 4 + 2 * (Code[pc+4] = INTEGER_CHECK)
	if TypeIs(Code[pc+1], TYPE_INTEGER) and
	    target_val[MIN] = target_val[MAX] and
	    target_val[MAX]+1 <= MAXINT then
	    -- constant fold 
	    c_stmt("@ = ", Code[pc+3])
	    c_printf("%d;\n", target_val[MIN]+1)
	    target_type = TYPE_INTEGER
	    target_val[MIN] += 1
	    target_val[MAX] += 1
	    ov = FALSE
		
	else 
	    c_stmt("@ = @ + 1;\n", {Code[pc+3], Code[pc+1]})
			
	    if TypeIs(Code[pc+1], TYPE_INTEGER) then
		if target_val[MAX] < MAXINT then
		    target_val[MIN] += 1
		    target_val[MAX] += 1
		    ov = FALSE
			
		else    
		    target_val = novalue
		end if
	    end if

	    if SymTab[Code[pc+3]][S_GTYPE] = TYPE_INTEGER or 
		IntegerSize(np, Code[pc+3]) or 
		not ov then
		-- no overflow possible 
		if TypeIs(Code[pc+1], TYPE_INTEGER) then
		    target_type = TYPE_INTEGER
		end if
		    
	    else 
		-- destroy any value, check for overflow
		SetBBType(Code[pc+3], GType(Code[pc+3]), target_val, 
				  target_elem)
		c_stmt("if (@ > MAXINT)\n", Code[pc+3])
		c_stmt("@ = NewDouble((double)@);\n", {Code[pc+3], Code[pc+3]})
	    end if
	end if
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
	c_stmt0("else\n")
    end if
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then    
	if Code[pc] = PLUS1 then
	    c_stmt("@ = binary_op(PLUS, 1, @);\n", {Code[pc+3], Code[pc+1]})
	else 
	    c_stmt("@ = 1+(long)(DBL_PTR(@)->dbl);\n", {Code[pc+3], Code[pc+1]})
	end if
    end if
		
    CDeRefStr("_0")
		
    SetBBType(Code[pc+3], target_type, target_val, target_elem)
    pc = np
end procedure

procedure opRETURNT()  
-- return from top-level "procedure"
    if cfile_size > MAX_CFILE_SIZE then
	c_stmt0("main")
	c_printf("%d();\n", main_name_num)
	c_stmt0("}\n")
	main_name = sprintf("main-%d", main_name_num)
	new_c_file(main_name)
	c_stmt0("main")
	c_printf("%d()\n", main_name_num)
	c_stmt0("{\n")
	main_temps()
	c_stmt0("\n")
	main_name_num += 1
    end if
    pc += 1
    if pc > length(Code) then
	all_done = TRUE
    end if
end procedure
	    
procedure opGLOBAL_INIT_CHECK() 
-- init checks - ignored by Translator
-- GLOBAL_INIT_CHECK / PRIVATE_INIT_CHECK 
    pc += 2
end procedure
	    
procedure opLHS_SUBS() 
-- LHS_SUBS / LHS_SUBS1 / LHS_SUBS1_COPY 
    SymTab[CurrentSub][S_LHS_SUBS2] = TRUE -- need to declare _3
	    
    if opcode = LHS_SUBS then
	-- temp has pointer to sequence
	c_stmt0("_2 = (int)SEQ_PTR(*(object_ptr)_3);\n")
	    
    elsif opcode = LHS_SUBS1 then
	-- sequence is stored in a variable
	c_stmt("_2 = (int)SEQ_PTR(@);\n", Code[pc+1])
	    
    else
	-- LHS_SUBS1_COPY
	c_stmt("DeRef(@);\n", Code[pc+4])
	c_stmt("@ = @;\n", {Code[pc+4], Code[pc+1]})
	c_stmt("Ref(@);\n", Code[pc+4])
	c_stmt("_2 = (int)SEQ_PTR(@);\n", Code[pc+4])
	target[MIN] = SeqLen(Code[pc+1])
	SetBBType(Code[pc+4], TYPE_SEQUENCE, target, SeqElem(Code[pc+1]))               
    end if
	    
    c_stmt0("if (!UNIQUE(_2)) {\n")
    c_stmt0("_2 = (int)SequenceCopy((s1_ptr)_2);\n")
	    
    if opcode = LHS_SUBS then
	c_stmt0("*(object_ptr)_3 = MAKE_SEQ(_2);\n")
	    
    elsif opcode = LHS_SUBS1 then
	c_stmt("@ = MAKE_SEQ(_2);\n", Code[pc+1])
	    
    else
	-- LHS_SUBS1_COPY
	c_stmt("@ = MAKE_SEQ(_2);\n", Code[pc+4])
    end if
	    
    c_stmt0("}\n")
	    
    if TypeIsNot(Code[pc+2], TYPE_INTEGER) then
	c_stmt("if (!IS_ATOM_INT(@))\n", Code[pc+2])
	c_stmt("_3 = (int)(((s1_ptr)_2)->base + (int)(DBL_PTR(@)->dbl));\n", 
		Code[pc+2])
	c_stmt0("else\n")
    end if
	    
    c_stmt("_3 = (int)(@ + ((s1_ptr)_2)->base);\n", Code[pc+2])
    target[MIN] = -1
    -- SetBBType(Code[pc+3], TYPE_SEQUENCE, target, TYPE_OBJECT)          
    pc += 5
end procedure
	    
procedure opASSIGN_OP_SLICE()
-- ASSIGN_OP_SLICE / PASSIGN_OP_SLICE   
-- var[i..j] op= expr
-- Note: _3 is set by above op 
		
    c_stmt("rhs_slice_target = (object_ptr)&@;\n", Code[pc+4])
    if opcode = PASSIGN_OP_SLICE then
	-- adjust etype of Code[pc+1]? - no, not the top level
	c_stmt0("assign_slice_seq = (s1_ptr *)_3;\n")
	c_stmt("RHS_Slice((s1_ptr)*(int *)_3, @, @);\n", 
	       {Code[pc+2], Code[pc+3]})
    else 
	c_stmt("assign_slice_seq = (s1_ptr *)&@;\n", Code[pc+1])
	target[MIN] = -1
	SetBBType(Code[pc+1], TYPE_SEQUENCE, target, TYPE_OBJECT) 
	-- OR-in the element type
	c_stmt("RHS_Slice((s1_ptr)@, @, @);\n", 
	       {Code[pc+1], Code[pc+2], Code[pc+3]})
    end if
    SetBBType(Code[pc+4], TYPE_SEQUENCE, novalue, TYPE_OBJECT) 
    --length might be knowable
    pc += 5
end procedure
	    
procedure opASSIGN_SLICE()
-- ASSIGN_SLICE / PASSIGN_SLICE  
-- var[i..j] = expr
    if previous_previous_op = ASSIGN_OP_SLICE or 
       previous_previous_op = PASSIGN_OP_SLICE then
	-- optimization, assumes no call to other Euphoria routine
	-- between [P]ASSIGN_OP_SLICE and here
	-- assign_slice_seq has already been set
	-- adjust etype - handle assign_op_slice too!!!
    elsif opcode = PASSIGN_SLICE then
	c_stmt0("assign_slice_seq = (s1_ptr *)_3;\n")
    else 
	c_stmt("assign_slice_seq = (s1_ptr *)&@;\n", Code[pc+1])
	target[MIN] = -1
	SetBBType(Code[pc+1], TYPE_SEQUENCE, target, GType(Code[pc+4])) 
	-- OR-in the element type
    end if
    c_stmt("AssignSlice(@, @, @);\n", {Code[pc+2], Code[pc+3], Code[pc+4]})
    pc += 5
end procedure

procedure opRHS_SLICE()
-- rhs slice of a sequence a[i..j] 
    sequence left_val, right_val
    integer t, preserve
    
    t = Code[pc+4]
    c_stmt("rhs_slice_target = (object_ptr)&@;\n", t)
    c_stmt("RHS_Slice((s1_ptr)@, @, @);\n", {Code[pc+1], Code[pc+2], Code[pc+3]})
    target = {NOVALUE, 0}
    left_val = ObjMinMax(Code[pc+2])
    right_val = ObjMinMax(Code[pc+3])
    if left_val[MIN] = left_val[MAX] and right_val[MIN] = right_val[MAX] and
       left_val[MIN] != NOVALUE and right_val[MIN] != NOVALUE then
	-- we have definite values
	target[MIN] = right_val[MIN] - left_val[MIN] + 1
    end if
    
    if t = Code[pc+1] and SymTab[t][S_MODE] = M_NORMAL then
	-- don't let this operation affect our
	-- global idea of sequence element type
	preserve = SymTab[t][S_SEQ_ELEM_NEW]
	SetBBType(t, TYPE_SEQUENCE, target, SeqElem(Code[pc+1])) 
	SymTab[t][S_SEQ_ELEM_NEW] = preserve
    else
	SetBBType(t, TYPE_SEQUENCE, target, SeqElem(Code[pc+1])) 
    end if
    pc += 5
end procedure

procedure opTYPE_CHECK() 
-- type check for a user-defined type
-- this always follows a type-call
-- The Translator only performs the type-call and check,
-- when there are side-effects, and "with type_check" is ON 
    if TypeIs(Code[pc-1], TYPE_INTEGER) then
	c_stmt("if (@ == 0)\n", Code[pc-1])
	c_stmt0("RTFatal(\"user-defined type_check failure\");\n")
    else 
	c_stmt("if (@ != 1) {\n", Code[pc-1])
	c_stmt("if (@ == 0)\n", Code[pc-1])
	c_stmt0("RTFatal(\"user-defined type_check failure\");\n")
	c_stmt("if (!IS_ATOM_INT(@)) {\n", Code[pc-1])
	c_stmt("if (!(IS_ATOM_DBL(@) && DBL_PTR(@)->dbl != 0.0))\n", 
		{Code[pc-1], Code[pc-1]})
	c_stmt0("RTFatal(\"user-defined type_check failure\");\n")
	c_stmt0("}\n")
	c_stmt0("}\n")
    end if
    pc += 1
end procedure
	    
procedure opIS_AN_INTEGER()
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    if TypeIs(Code[pc+1], TYPE_INTEGER) then
	c_stmt("@ = 1;\n", Code[pc+2])
    elsif TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	c_stmt("@ = 0;\n", Code[pc+2])
    elsif TypeIs(Code[pc+1], TYPE_DOUBLE) then
	c_stmt("@ = IS_ATOM_INT(DoubleToInt(@));\n", {Code[pc+2], Code[pc+1]})
    else 
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
	c_stmt("@ = 1;\n", Code[pc+2])
	c_stmt("else if (IS_ATOM_DBL(@))\n", Code[pc+1])
	c_stmt("@ = IS_ATOM_INT(DoubleToInt(@));\n", {Code[pc+2], Code[pc+1]})
	c_stmt0("else\n")
	c_stmt("@ = 0;\n", Code[pc+2])
    end if
    CDeRefStr("_0")
    target = {0, 1}
    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 3
end procedure

procedure opIS_AN_ATOM()
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_DOUBLE}) then
	c_stmt("@ = 1;\n", Code[pc+2])
    elsif TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	c_stmt("@ = 0;\n", Code[pc+2])
    else 
	c_stmt("@ = IS_ATOM(@);\n", {Code[pc+2], Code[pc+1]})
    end if
    CDeRefStr("_0")
    target = {0, 1}
    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 3
end procedure
		
procedure opIS_A_SEQUENCE()
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_DOUBLE}) then
	c_stmt("@ = 0;\n", Code[pc+2])
    elsif TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	c_stmt("@ = 1;\n", Code[pc+2])
    else 
	c_stmt("@ = IS_SEQUENCE(@);\n", {Code[pc+2], Code[pc+1]})
    end if
    CDeRefStr("_0")
    target = {0, 1}
    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 3
end procedure
	    
procedure opIS_AN_OBJECT()
    CDeRef(Code[pc+2])
    c_stmt("@ = 1;\n", Code[pc+2])
    target = {1, 1}
    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 3
end procedure
		
	-- ---------- start of unary ops ----------------- 

procedure opSQRT()
    CUnaryOp(pc, "e_sqrt", "SQRT")
    pc += 3
end procedure
	
procedure opSIN()
    CUnaryOp(pc, "e_sin", "SIN")
    pc += 3
end procedure

procedure opCOS()
    CUnaryOp(pc, "e_cos", "COS")
    pc += 3
end procedure

procedure opTAN()
    CUnaryOp(pc, "e_tan", "TAN")
    pc += 3
end procedure

procedure opARCTAN()
    CUnaryOp(pc, "e_arctan", "ARCTAN")
    pc += 3
end procedure

procedure opLOG()
    CUnaryOp(pc, "e_log", "LOG")
    pc += 3
end procedure

procedure opNOT_BITS()
    CUnaryOp(pc, "not_bits", "NOT_BITS")
    pc += 3
end procedure

procedure opFLOOR()
    CUnaryOp(pc, "e_floor", "FLOOR")
    pc += 3
end procedure

	-- more unary ops - better optimization 
	    
procedure opNOT_IFW()
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
    end if  
	    
    if TypeIs(Code[pc+1], TYPE_INTEGER) then
	-- optimize if possible
	
	if ObjValue(Code[pc+1]) = 0 then
	    -- optimize: no jump, continue into the block
	
	elsif ObjValue(Code[pc+1]) = NOVALUE or 
	      forward_branch_into(pc+3, Code[pc+2]-1) then
	    if ObjValue(Code[pc+1]) = NOVALUE then -- zero handled above
		c_stmt("if (@ != 0)\n", Code[pc+1])
	    end if          
	    Goto(Code[pc+2])
	
	else
	    pc = Code[pc+2] -- known, non-zero value, skip whole block
	    return
	end if
    
    elsif TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (@ != 0)\n", Code[pc+1])
	Goto(Code[pc+2])
    
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    end if
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	c_stmt("if (DBL_PTR(@)->dbl != 0.0)\n", Code[pc+1])
	Goto(Code[pc+2])
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then 
	c_stmt0("}\n")
    end if  
    
    pc += 3
end procedure
	    
procedure opNOT()
    gencode = "@ = unary_op(NOT, @);\n"
    intcode = "@ = (@ == 0);\n"
    if TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_type = GType(Code[pc+1])
    else
	target_type = TYPE_INTEGER
    end if
    pc = unary_optimize(pc, target_type, target_val, intcode, intcode2,
			gencode)
end procedure

procedure opUMINUS()
    gencode = "@ = unary_op(UMINUS, @);\n"
    intcode2= "@1 = - @2;\n"    -- careful about -- occurring
    intcode = "if (@2 == 0xC0000000)\n" &
	      "@1 = (int)NewDouble((double)-0xC0000000);\n" &
	      "else\n" &
	      "@1 = - @2;\n"    -- careful about -- occurring
    if GType(Code[pc+1]) = TYPE_INTEGER then
	if NotInRange(Code[pc+1], MININT) then
	    target_type = TYPE_INTEGER
	else                    
	    target_type = TYPE_ATOM
	end if
    else
	target_type = GType(Code[pc+1])
    end if
    pc = unary_optimize(pc, target_type, target_val, intcode, intcode2,
			gencode)
end procedure
	    
procedure opRAND()
    gencode = "@ = unary_op(RAND, @);\n"
    intcode = "@ = good_rand() % ((unsigned)@) + 1;\n"
    if TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_type = GType(Code[pc+1])
    else 
	target_type = TYPE_INTEGER
	if TypeIs(Code[pc+1], TYPE_INTEGER) then
	    target = ObjMinMax(Code[pc+1])
	    target_val = {1, target[MAX]}
	end if
    end if
	     
    pc = unary_optimize(pc, target_type, target_val, intcode, intcode2,
			gencode) 
end procedure
	    
procedure opDIV2()
-- like unary, but pc+=4, Code[pc+2] ignored
    gencode = "@ = binary_op(DIVIDE, @, 2);\n"
    intcode = "if (@2 & 1) {\n" &
	      "@1 = NewDouble((@2 >> 1) + 0.5);\n" &
	      "}\n" &
	      "else\n" &
	      "@1 = @2 >> 1;\n"
    if GType(Code[pc+1]) = TYPE_INTEGER then
	target_type = TYPE_ATOM
    else
	target_type = GType(Code[pc+1])
    end if
    unary_div(pc, target_type, intcode, gencode)
    pc += 4 
end procedure
	    
procedure opFLOOR_DIV2()
    gencode = "_1 = binary_op(DIVIDE, @2, 2);\n" &
	      "@1 = unary_op(FLOOR, _1);\n" &
	      "DeRef(_1);\n" 
    intcode = "@ = @ >> 1;\n"
    if TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_type = GType(Code[pc+1])
    elsif GType(Code[pc+1]) = TYPE_INTEGER then
	target_type = TYPE_INTEGER
    else
	target_type = TYPE_ATOM
    end if 

    unary_div(pc, target_type, intcode, gencode)
    pc += 4 
end procedure            
		
	------------ start of binary ops ----------
	    
procedure opGREATER_IFW()
    pc = ifw(pc, "LESSEQ", "<=")
end procedure
	
procedure opNOTEQ_IFW()
    pc = ifw(pc, "EQUALS", "==")
end procedure
	
procedure opLESSEQ_IFW()
    pc = ifw(pc, "GREATER", ">")
end procedure
	
procedure opGREATEREQ_IFW()
    pc = ifw(pc, "LESS", "<")
end procedure       
	
procedure opEQUALS_IFW()
    pc = ifw(pc, "NOTEQ", "!=")
end procedure       
	
procedure opLESS_IFW()
    pc = ifw(pc, "GREATEREQ", ">=")
end procedure           
	
-- relops part of if or while with integers condition

procedure opLESS_IFW_I()
    pc = ifwi(pc, ">=") 
end procedure
	
procedure opGREATER_IFW_I()
    pc = ifwi(pc, "<=")
end procedure
	
procedure opEQUALS_IFW_I()
    pc = ifwi(pc, "!=")
end procedure       
	
procedure opNOTEQ_IFW_I()
    pc = ifwi(pc, "==")
end procedure       
	
procedure opLESSEQ_IFW_I()
    pc = ifwi(pc, ">")
end procedure       
	
procedure opGREATEREQ_IFW_I()
    pc = ifwi(pc, "<")
end procedure           
	
-- other binary ops
	
procedure opMULTIPLY()
    gencode = "@ = binary_op(MULTIPLY, @, @);\n"
    intcode2= "@1 = @2 * @3;\n"
    -- quick range test - could expand later maybe
    intcode = IntegerMultiply(Code[pc+1], Code[pc+2])
    if TypeIs(Code[pc+1], TYPE_DOUBLE) or
       TypeIs(Code[pc+2], TYPE_DOUBLE) then
	atom_type = TYPE_DOUBLE
    end if
    iii = FALSE
    dblfn="*"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opPLUS()
-- PLUS / PLUS_I
    gencode = "@ = binary_op(PLUS, @, @);\n"
    intcode2= "@1 = @2 + @3;\n"
    intcode = "@1 = @2 + @3;\n"
    intcode_extra = "if ((long)((unsigned long)@1 + (unsigned long)HIGH_BITS) >= 0) \n" &
		    "@1 = NewDouble((double)@1);\n"
    if TypeIs(Code[pc+1], TYPE_DOUBLE) or
       TypeIs(Code[pc+2], TYPE_DOUBLE) then
	atom_type = TYPE_DOUBLE
    end if
    iii = FALSE
    dblfn="+"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opMINUS()
-- MINUS / MINUS_I
    gencode = "@ = binary_op(MINUS, @, @);\n"
    intcode2 ="@1 = @2 - @3;\n"
    intcode = "@1 = @2 - @3;\n"
    intcode_extra = "if ((long)((unsigned long)@1 +(unsigned long) HIGH_BITS) >= 0)\n" &
		    "@1 = NewDouble((double)@1);\n"
    if TypeIs(Code[pc+1], TYPE_DOUBLE) or
       TypeIs(Code[pc+2], TYPE_DOUBLE) then
	atom_type = TYPE_DOUBLE
    end if
    iii = FALSE
    dblfn="-"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opOR()
    gencode = "@ = binary_op(OR, @, @);\n"
    intcode = "@ = (@ != 0 || @ != 0);\n"
    atom_type = TYPE_INTEGER
    iii = TRUE
    dblfn="Dor"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opXOR()
    gencode = "@ = binary_op(XOR, @, @);\n"
    intcode = "@ = ((@ != 0) != (@ != 0));\n"
    atom_type = TYPE_INTEGER
    iii = TRUE
    dblfn="Dxor"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opAND()
    gencode = "@ = binary_op(AND, @, @);\n"
    intcode = "@ = (@ != 0 && @ != 0);\n"
    atom_type = TYPE_INTEGER
    iii = TRUE
    dblfn="Dand"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opDIVIDE()
    if TypeIs(Code[pc+2], TYPE_INTEGER) and 
       ObjValue(Code[pc+2]) = 0 then
	intcode = "RTFatal(\"divide by 0\");\n"
	gencode = intcode
    else 
	gencode = "@ = binary_op(DIVIDE, @, @);\n"
	intcode = "@1 = (@2 % @3) ? NewDouble((double)@2 / @3) : (@2 / @3);\n"
    end if
    if TypeIs(Code[pc+1], TYPE_DOUBLE) or
       TypeIs(Code[pc+2], TYPE_DOUBLE) then
	atom_type = TYPE_DOUBLE
    end if
    iii = FALSE
    dblfn="/"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure

procedure opREMAINDER()
    gencode = "@ = binary_op(REMAINDER, @, @);\n"
    intcode = "@ = (@ % @);\n"
    if TypeIs(Code[pc+2], TYPE_INTEGER) then
	if ObjValue(Code[pc+2]) = 0 then
	    intcode = "RTFatal(\"remainder of a number divided by 0\");\n"
	    gencode = intcode
	elsif TypeIs(Code[pc+1], TYPE_INTEGER) then
	    target_val = ObjMinMax(Code[pc+2])                      
	    target_val[MAX] = max(abs(target_val[MIN]), 
					    abs(target_val[MAX])) - 1
	    target_val[MIN] = -target_val[MAX]
	end if
    end if
    if TypeIs(Code[pc+1], TYPE_DOUBLE) or
       TypeIs(Code[pc+2], TYPE_DOUBLE) then
	atom_type = TYPE_DOUBLE
    end if
    iii = TRUE
    dblfn="Dremainder"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opFLOOR_DIV()
    gencode = "_2 = binary_op(DIVIDE, @2, @3);\n" &
	      "@1 = unary_op(FLOOR, _2);\n" &
	      "DeRef(_2);\n"
		
    -- N.B. floor_div(MININT/-1) is not an integer

    intcode2 = "if (@3 > 0 && @2 >= 0) {\n" &
	       "@1 = @2 / @3;\n" &
	       "}\n" &
	       "else {\n" &
	       "temp_dbl = floor((double)@2 / (double)@3);\n" &
	       "@1 = (long)temp_dbl;\n" &
	       "}\n"
		
    if GType(Code[pc+1]) = TYPE_INTEGER and
       GType(Code[pc+2]) = TYPE_INTEGER and
       NotInRange(Code[pc+1], MININT) and
       NotInRange(Code[pc+2], -1) then
	intcode = intcode2
	iii = TRUE
    else 
	intcode = "if (@3 > 0 && @2 >= 0) {\n" &
		  "@1 = @2 / @3;\n" &
		  "}\n" &
		  "else {\n" &
		  "temp_dbl = floor((double)@2 / (double)@3);\n" &
		  "if (@2 != MININT)\n" &
		  "@1 = (long)temp_dbl;\n" &
		  "else\n" &
		  "@1 = NewDouble(temp_dbl);\n" &
		  "}\n"
	iii = FALSE
    end if
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opAND_BITS()
    gencode = "@ = binary_op(AND_BITS, @, @);\n"
    intcode = "@ = (@ & @);\n"
    iii = TRUE
    dblfn="Dand_bits"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opOR_BITS()
    gencode = "@ = binary_op(OR_BITS, @, @);\n"
    intcode = "@ = (@ | @);\n"
    iii = TRUE
    dblfn="Dor_bits"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opXOR_BITS()
    gencode = "@ = binary_op(XOR_BITS, @, @);\n"
    intcode = "@ = (@ ^ @);\n"
    iii = TRUE
    dblfn="Dxor_bits"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opPOWER()
    gencode = "@ = binary_op(POWER, @, @);\n"
    intcode = "@ = power(@, @);\n"
    intcode2 = intcode
    if TypeIs(Code[pc+1], TYPE_DOUBLE) or
       TypeIs(Code[pc+2], TYPE_DOUBLE) then
	atom_type = TYPE_DOUBLE
    end if
    iii = FALSE
    dblfn="Dpower"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	    
procedure opLESS()
    gencode = "@ = binary_op(LESS, @, @);\n"
    intcode = "@ = (@ < @);\n"
    atom_type = TYPE_INTEGER
    if TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
       TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_val = {0, 1}
    end if
    iii = TRUE
    dblfn="<"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opGREATER()
    gencode = "@ = binary_op(GREATER, @, @);\n"
    intcode = "@ = (@ > @);\n"
    atom_type = TYPE_INTEGER
    if TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
       TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_val = {0, 1}
    end if
    iii = TRUE
    dblfn=">"
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opEQUALS()
    gencode = "@ = binary_op(EQUALS, @, @);\n"
    intcode = "@ = (@ == @);\n"
    atom_type = TYPE_INTEGER
    if TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
       TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_val = {0, 1}
    end if
    iii = TRUE
    dblfn="=="
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opNOTEQ()
    gencode = "@ = binary_op(NOTEQ, @, @);\n"
    intcode = "@ = (@ != @);\n"
    atom_type = TYPE_INTEGER
    if TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
       TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_val = {0, 1}
    end if
    iii = TRUE
    dblfn="!="
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opLESSEQ()
    gencode = "@ = binary_op(LESSEQ, @, @);\n"
    intcode = "@ = (@ <= @);\n"
    atom_type = TYPE_INTEGER
    if TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
       TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_val = {0, 1}
    end if
    iii = TRUE
    dblfn="<="
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure
	
procedure opGREATEREQ()
    gencode = "@ = binary_op(GREATEREQ, @, @);\n"
    intcode = "@ = (@ >= @);\n"
    atom_type = TYPE_INTEGER
    if TypeIsNot(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) and
       TypeIsNot(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	target_val = {0, 1}
    end if
    iii = TRUE
    dblfn = ">="
    pc = binary_op(pc, iii, target_val, intcode, intcode2,
		   intcode_extra, gencode, dblfn, atom_type)
end procedure           
-- end of binary ops 

-- short-circuit ops 
	    
procedure opSC1_AND()  
-- SC1_AND / SC1_AND_IF
-- no need to store ATOM_0
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then 
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
    end if
		
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (@ == 0) {\n", Code[pc+1])
	if Code[pc] = SC1_AND then
	    CDeRef(Code[pc+2])
	    c_stmt("@ = 0;\n", Code[pc+2]) -- hard to suppress
	end if
	Goto(Code[pc+3])
	c_stmt0("}\n")
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    end if
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	c_stmt("if (DBL_PTR(@)->dbl == 0.0) {\n", Code[pc+1])
	if Code[pc] = SC1_AND then
	    CDeRef(Code[pc+2])
	    c_stmt("@ = 0;\n", Code[pc+2])
	end if
	Goto(Code[pc+3])
	c_stmt0("}\n")
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then 
	c_stmt0("}\n")
    end if
		
    if TypeIs(Code[pc+1], TYPE_INTEGER) then
	SetBBType(Code[pc+2], TYPE_INTEGER, novalue, TYPE_OBJECT)
    else
	SetBBType(Code[pc+2], TYPE_ATOM, novalue, TYPE_OBJECT)
    end if
    pc += 4
end procedure

procedure opSC1_OR() 
-- SC1_OR / SC1_OR_IF
-- no need to store ATOM_1
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then 
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
    end if
		
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (@ != 0) {\n", Code[pc+1]) -- optimize this???
	if Code[pc] = SC1_OR then
	    CDeRef(Code[pc+2])
	    c_stmt("@ = 1;\n", Code[pc+2])
	end if
	Goto(Code[pc+3])
	c_stmt0("}\n")
    end if
	    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    end if
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	c_stmt("if (DBL_PTR(@)->dbl != 0.0) {\n", Code[pc+1])
	if Code[pc] = SC1_OR then
	    CDeRef(Code[pc+2])
	    c_stmt("@ = 1;\n", Code[pc+2])
	end if
	Goto(Code[pc+3])
	c_stmt0("}\n")
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
    end if
		
    if Code[pc] = SC1_OR then
	if TypeIs(Code[pc+1], TYPE_INTEGER) then
	    SetBBType(Code[pc+2], TYPE_INTEGER, novalue, TYPE_OBJECT)
	else
	    SetBBType(Code[pc+2], TYPE_ATOM, novalue, TYPE_OBJECT)
	end if
    end if
    pc += 4
end procedure
		
procedure opSC2_OR()
-- SC2_OR / SC2_AND
    CDeRef(Code[pc+2])
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    end if
		
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("@ = (@ != 0);\n", {Code[pc+2], Code[pc+1]})
    end if
	    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("else\n", Code[pc+1])
    end if
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	c_stmt("@ = DBL_PTR(@)->dbl != 0.0;\n", {Code[pc+2], Code[pc+1]})
    end if
	    
    SetBBType(Code[pc+2], TYPE_INTEGER, novalue, TYPE_OBJECT)
    pc += 3
end procedure

-- for loops 
	    
procedure opFOR()
-- generate code for FOR, FOR_I 
    sequence range1, range2, inc
    
    in_loop = append(in_loop, Code[pc+5]) -- loop var
    c_stmt("{ int @;\n", Code[pc+5])
		
    CRef(Code[pc+3])
    c_stmt("@ = @;\n", {Code[pc+5], Code[pc+3]})
		
    Label(pc+7)
		
    inc = ObjMinMax(Code[pc+1])
    if TypeIs(Code[pc+1], TYPE_INTEGER) then 
	-- increment is an integer
		    
	if TypeIs(Code[pc+3], TYPE_INTEGER) and
	   TypeIs(Code[pc+2], TYPE_INTEGER) then
	    -- loop var is an integer
	    range1 = ObjMinMax(Code[pc+3])  -- start
	    range2 = ObjMinMax(Code[pc+2])  -- limit
	    SymTab[Code[pc+5]][S_GTYPE] = TYPE_INTEGER    
	else 
	    range1 = {NOVALUE, NOVALUE}
	    SymTab[Code[pc+5]][S_GTYPE] = TYPE_ATOM    
	    SymTab[Code[pc+5]][S_OBJ] = NOVALUE
	end if   
		    
	if inc[MIN] >= 0 then
	    -- going up 
	    LeftSym = TRUE
	    if TypeIs(Code[pc+5], TYPE_INTEGER) and
	       TypeIs(Code[pc+2], TYPE_INTEGER) then
		c_stmt("if (@ > @)\n", {Code[pc+5], Code[pc+2]})
	    else 
		c_stmt("if (binary_op_a(GREATER, @, @))\n", {Code[pc+5], Code[pc+2]})
	    end if
	    Goto(Code[pc+6])
	    if range1[MIN] != NOVALUE then
		SymTab[Code[pc+5]][S_OBJ_MIN] = range1[MIN]
		SymTab[Code[pc+5]][S_OBJ_MAX] = max(range1[MAX], range2[MAX])  
	    end if
		
	elsif inc[MAX] < 0 then
	    -- going down 
	    LeftSym = TRUE
	    if TypeIs(Code[pc+5], TYPE_INTEGER) and
	       TypeIs(Code[pc+2], TYPE_INTEGER) then
		c_stmt("if (@ < @)\n", {Code[pc+5], Code[pc+2]})
	    else 
		c_stmt("if (binary_op_a(LESS, @, @))\n", {Code[pc+5], Code[pc+2]})
	    end if
	    Goto(Code[pc+6])
	    if range1[MIN] != NOVALUE then
		SymTab[Code[pc+5]][S_OBJ_MIN] = min(range1[MIN], range2[MIN])  
		SymTab[Code[pc+5]][S_OBJ_MAX] = range1[MAX]
	    end if
		
	else 
	    -- integer, but value could be + or - 
	    c_stmt("if (@ >= 0) {\n", Code[pc+1])
			
	    LeftSym = TRUE
	    if TypeIs(Code[pc+5], TYPE_INTEGER) and
	       TypeIs(Code[pc+2], TYPE_INTEGER) then
		c_stmt("if (@ > @)\n", {Code[pc+5], Code[pc+2]})
	    else 
		c_stmt("if (binary_op_a(GREATER, @, @))\n", 
					       {Code[pc+5], Code[pc+2]})
	    end if
	    Goto(Code[pc+6])
	    c_stmt0("}\n")
	    c_stmt0("else {\n")
	    LeftSym = TRUE
	    if TypeIs(Code[pc+5], TYPE_INTEGER) and
	       TypeIs(Code[pc+2], TYPE_INTEGER) then
		c_stmt("if (@ < @)\n", {Code[pc+5], Code[pc+2]})
	    else 
		c_stmt("if (binary_op_a(LESS, @, @))\n", 
					       {Code[pc+5], Code[pc+2]})
	    end if
	    Goto(Code[pc+6])
	    if range1[MIN] != NOVALUE then
		SymTab[Code[pc+5]][S_OBJ_MIN] = min(range1[MIN], range2[MIN])
		SymTab[Code[pc+5]][S_OBJ_MAX] = max(range1[MAX], range2[MAX])
	    end if
	    c_stmt0("}\n")
	end if
	    
    else 
	-- increment type is not known to be integer
		
	c_stmt("if (@ >= 0) {\n", Code[pc+1])
	c_stmt("if (binary_op_a(GREATER, @, @))\n", {Code[pc+5], Code[pc+2]})
	Goto(Code[pc+6])
	c_stmt0("}\n")
	c_stmt("else if (IS_ATOM_INT(@)) {\n", Code[pc+1])
	c_stmt("if (binary_op_a(LESS, @, @))\n", {Code[pc+5], Code[pc+2]})
	Goto(Code[pc+6])
	c_stmt0("}\n")
		    
	c_stmt0("else {\n")
	c_stmt("if (DBL_PTR(@)->dbl >= 0.0) {\n", Code[pc+1])          
	c_stmt("if (binary_op_a(GREATER, @, @))\n", {Code[pc+5], Code[pc+2]})
	Goto(Code[pc+6])
	c_stmt0("}\n")
	c_stmt0("else {\n")
	c_stmt("if (binary_op_a(LESS, @, @))\n", {Code[pc+5], Code[pc+2]})
	Goto(Code[pc+6])
	c_stmt0("}\n")
	c_stmt0("}\n")
	    
    end if

    pc += 7
end procedure

procedure opENDFOR_GENERAL()
-- ENDFOR_INT_UP1 / ENDFOR_INT_UP / ENDFOR_UP / ENDFOR_INT_DOWN1
-- ENDFOR_INT_DOWN / ENDFOR_DOWN / ENDFOR_GENERAL
    boolean close_brace
    sequence gencode, intcode
    
    in_loop = in_loop[1..length(in_loop)-1]
    CSaveStr("_0", Code[pc+3], Code[pc+3], Code[pc+4], 0)
    -- always delay the DeRef
		
    close_brace = FALSE
    gencode = "@ = binary_op_a(PLUS, @, @);\n"

    -- rvalue for CName should be ok - we've initialized loop var
    intcode = "@1 = @2 + @3;\n" &
	      "if ((long)((unsigned long)@1 +(unsigned long) HIGH_BITS) >= 0) \n" &
	      "@1 = NewDouble((double)@1);\n"
		
    if TypeIs(Code[pc+3], TYPE_INTEGER) and 
       TypeIs(Code[pc+4], TYPE_INTEGER) then
	-- uncertain about neither operand and target is integer
	c_stmt("@1 = @2 + @3;\n", {Code[pc+3], Code[pc+3], Code[pc+4]})
	    
    elsif TypeIs(Code[pc+3], TYPE_INTEGER) and 
	  TypeIs(Code[pc+4], {TYPE_ATOM, TYPE_OBJECT}) then
	    -- target and one operand are integers
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+4])
	c_stmt("@1 = @2 + @3;\n", {Code[pc+3], Code[pc+3], Code[pc+4]})
	c_stmt0("}\n")
	c_stmt0("else {\n")
	close_brace = TRUE
	    
    elsif TypeIs(Code[pc+4], TYPE_INTEGER) and
	  TypeIs(Code[pc+3], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+3])
	c_stmt(intcode, {Code[pc+3], Code[pc+3], Code[pc+4]})
	c_stmt0("}\n")
	c_stmt0("else {\n")
	close_brace = TRUE
    end if
		
    if TypeIs(Code[pc+3], {TYPE_ATOM, TYPE_OBJECT}) and
       TypeIs(Code[pc+4], {TYPE_ATOM, TYPE_OBJECT}) then
	-- uncertain about both types being TYPE_INTEGER or not
	c_stmt("if (IS_ATOM_INT(@) && IS_ATOM_INT(@)) {\n", 
	       {Code[pc+3], Code[pc+4]})
	c_stmt(intcode, {Code[pc+3], Code[pc+3], Code[pc+4]})
	c_stmt0("}\n")
	c_stmt0("else {\n")
	close_brace = TRUE
    end if

    if TypeIsNot(Code[pc+3], TYPE_INTEGER) or 
       TypeIsNot(Code[pc+4], TYPE_INTEGER) then
	c_stmt(gencode, {Code[pc+3], Code[pc+3], Code[pc+4]})
    end if

    if close_brace then
	c_stmt0("}\n")
    end if
		
    CDeRefStr("_0")

    Goto(Code[pc+1])
    Label(pc+5)
    c_stmt0(";\n")
		
    CDeRef(Code[pc+3])
    c_stmt0("}\n")
    -- no SetBB needed here - it's a loop variable 
    -- (and it's in a local block)
	    
    pc += 5
end procedure

procedure opCALL_PROC()
-- CALL_PROC / CALL_FUNC 
-- Call by routine id to Euphoria procedure, function or type.
-- Note that dlls and main programs can't share routine ids, so it's
-- OK to compute last_max_params just within dll or within main program.

    if last_routine_id > 0 or Code[pc] = CALL_FUNC then
	-- only generate code if routine_id() 
	-- was called somewhere, or it's a call_func - otherwise
	-- return value temp might be used but not declared 
		    
	if TypeIs(Code[pc+2], TYPE_SEQUENCE) then
	    len = SeqLen(Code[pc+2])
	else
	    len = NOVALUE
	end if
		    
	if len != 0 then
	    c_stmt("_1 = (int)SEQ_PTR(@);\n", Code[pc+2])
	    c_stmt0("_2 = (int)((s1_ptr)_1)->base;\n")
	end if
		
	c_stmt("_0 = (int)_00[@].addr;\n", Code[pc+1])
		    
	if len = NOVALUE then
	    c_stmt0("switch(((s1_ptr)_1)->length) {\n")
	end if
		    
	for i = 0 to last_max_params do
	    if len = NOVALUE then
		c_stmt0("case ")
		c_printf("%d:\n", i)
		indent += 4
		-- N.B. have to Ref all the args too
	    end if
	    if len = NOVALUE or len = i then
		for k = 1 to i do
		    c_stmt0("Ref(*(int *)(_2+")
		    c_printf("%d));\n", k * 4)
		end for
			
		if EWINDOWS and dll_option then
		    c_stmt("if (_00[@].convention) {\n", Code[pc+1])
		    if Code[pc] = CALL_FUNC then 
			c_stmt0("_1 = (*(int (__stdcall *)())_0)(\n")
			arg_list(i)
			c_stmt0("}\n")
			c_stmt0("else {\n")
			c_stmt0("_1 = (*(int (*)())_0)(\n")
		    else
			c_stmt0("(*(int (__stdcall *)())_0)(\n")
			arg_list(i)
			c_stmt0("}\n")
			c_stmt0("else {\n")
			c_stmt0("(*(int (*)())_0)(\n")
		    end if
		    arg_list(i)
		    c_stmt0("}\n")
		else
		    if Code[pc] = CALL_FUNC then 
			c_stmt0("_1 = (*(int (*)())_0)(\n")
		    else
			c_stmt0("(*(int (*)())_0)(\n")
		    end if
		    arg_list(i)
		end if
			
	    end if
	    if len = NOVALUE then
		c_stmt0("break;\n")
		indent -= 4
	    end if
	end for
	if len = NOVALUE then
	    c_stmt0("}\n")
	end if
		    
	NewBB(1, E_ALL_EFFECT, 0) -- Windows call-back to Euphoria routine could occur
		    
	if Code[pc] = CALL_FUNC then
	    CDeRef(Code[pc+3])
	    c_stmt("@ = _1;\n", Code[pc+3])
	    SymTab[Code[pc+3]][S_ONE_REF] = FALSE
	    -- hard to ever know the return type here
	    SetBBType(Code[pc+3], TYPE_OBJECT, novalue, TYPE_OBJECT)
	end if
    end if
    pc += 3 + (Code[pc] = CALL_FUNC)
end procedure
	      
procedure opCALL_BACK_RETURN()
    pc += 1
    all_done = TRUE
end procedure               
	
procedure opBADRETURNF() 
-- shouldn't reach here
    pc += 1
    all_done = TRUE  -- end of a function
end procedure

procedure opRETURNF()
-- generate code for return from function   
    symtab_index sym, sub
    boolean doref
    sequence x
	    
    sub = Code[pc+1]
		
    -- update function return type, and sequence element type
    SymTab[sub][S_GTYPE_NEW] = or_type(SymTab[sub][S_GTYPE_NEW], 
				       GType(Code[pc+2]))
    SymTab[sub][S_SEQ_ELEM_NEW] = or_type(SymTab[sub][S_SEQ_ELEM_NEW], 
					     SeqElem(Code[pc+2]))
		
    if GType(Code[pc+2]) = TYPE_INTEGER then
	x = ObjMinMax(Code[pc+2])
	if SymTab[sub][S_OBJ_MIN_NEW] = -NOVALUE then
	    SymTab[sub][S_OBJ_MIN_NEW] = x[MIN]
	    SymTab[sub][S_OBJ_MAX_NEW] = x[MAX]
		
	elsif SymTab[sub][S_OBJ_MIN_NEW] != NOVALUE then
	    if x[MIN] < SymTab[sub][S_OBJ_MIN_NEW] then
		SymTab[sub][S_OBJ_MIN_NEW] = x[MIN]
	    end if
	    if x[MAX] > SymTab[sub][S_OBJ_MAX_NEW] then
		SymTab[sub][S_OBJ_MAX_NEW] = x[MAX]
	    end if
	end if
	    
    elsif GType(Code[pc+2]) = TYPE_SEQUENCE then
	if SymTab[sub][S_SEQ_LEN_NEW] = -NOVALUE then
	    SymTab[sub][S_SEQ_LEN_NEW] = SeqLen(Code[pc+2])
	elsif SymTab[sub][S_SEQ_LEN_NEW] != SeqLen(Code[pc+2]) then
	    SymTab[sub][S_SEQ_LEN_NEW] = NOVALUE
	end if
	    
    else 
	SymTab[sub][S_OBJ_MIN_NEW] = NOVALUE
	SymTab[sub][S_SEQ_LEN_NEW] = NOVALUE
	    
    end if
		
    doref = TRUE
    
    -- deref any active for-loop vars
    for i = 1 to length(in_loop) do
	if in_loop[i] != 0 then
	    -- active for-loop var
	    if in_loop[i] = Code[pc+2] then
		doref = FALSE
	    else
		CDeRef(in_loop[i])
	    end if
	end if
    end for
    
    -- deref the temps and privates
    -- check if we are derefing the return var/temp
    if SymTab[Code[pc+2]][S_MODE] = M_TEMP then
	sym = SymTab[sub][S_TEMPS]
	while sym != 0 do
	    if SymTab[sym][S_SCOPE] != DELETED and 
	       SymTab[sym][S_TEMP_NAME] = SymTab[Code[pc+2]][S_TEMP_NAME] then
		doref = FALSE
		exit
	    end if
	    sym = SymTab[sym][S_NEXT]
	end while
	    
    else 
	-- non-temps
	sym = SymTab[sub][S_NEXT]
	while sym != 0 and SymTab[sym][S_SCOPE] <= SC_PRIVATE do
	    if SymTab[sym][S_SCOPE] != SC_LOOP_VAR and
	       SymTab[sym][S_SCOPE] != SC_GLOOP_VAR then
		if sym = Code[pc+2] then
		    doref = FALSE
		    exit
		end if
	    end if
	    sym = SymTab[sym][S_NEXT]
	end while
    end if
	    
    if doref then
	CRef(Code[pc+2])                
    end if  
	    
    SymTab[Code[pc+2]][S_ONE_REF] = FALSE
		
    -- DeRef private vars/temps before returning
		
    sym = SymTab[sub][S_NEXT]
    while sym != 0 and SymTab[sym][S_SCOPE] <= SC_PRIVATE do
	if SymTab[sym][S_SCOPE] != SC_LOOP_VAR and
	    SymTab[sym][S_SCOPE] != SC_GLOOP_VAR then
	    if sym != Code[pc+2] then
		CDeRef(sym)
	    end if
	end if
	sym = SymTab[sym][S_NEXT]
    end while
		
    sym = SymTab[sub][S_TEMPS]
    while sym != 0 do
	if SymTab[sym][S_SCOPE] != DELETED then  
	    if SymTab[Code[pc+2]][S_MODE] != M_TEMP or
	       SymTab[sym][S_TEMP_NAME] != SymTab[Code[pc+2]][S_TEMP_NAME] then
		-- temp type can be TYPE_NULL here if temp was not used
		FinalDeRef(sym)
	    end if
	end if
	sym = SymTab[sym][S_NEXT]
    end while
    FlushDeRef()
		
    c_stmt0("return ")
    CName(Code[pc+2])
    c_puts(";\n")

    pc += 3
end procedure

procedure opRETURNP()
-- return from procedure
    -- deref any active for-loop vars
    for i = 1 to length(in_loop) do
	if in_loop[i] != 0 then
	    -- active for-loop var
	    CDeRef(in_loop[i])
	end if
    end for
	    
    -- deref the temps and privates
    sub = Code[pc+1]
		
    sym = SymTab[sub][S_NEXT]
    while sym != 0 and SymTab[sym][S_SCOPE] <= SC_PRIVATE do
	if SymTab[sym][S_SCOPE] != SC_LOOP_VAR and
	   SymTab[sym][S_SCOPE] != SC_GLOOP_VAR then
	    CDeRef(sym)
	end if
	sym = SymTab[sym][S_NEXT]
    end while
		
    sym = SymTab[sub][S_TEMPS]
    while sym != 0 do
	if SymTab[sym][S_SCOPE] != DELETED then
	    FinalDeRef(sym)
	end if
	sym = SymTab[sym][S_NEXT]
    end while
    FlushDeRef()
    c_stmt0("return 0;\n")
    pc += 2
end procedure

procedure opROUTINE_ID()
    CSaveStr("_0", Code[pc+4], Code[pc+2], 0, 0)
    c_stmt("@ = CRoutineId(", Code[pc+4])
    c_printf("%d, ", Code[pc+1])  -- sequence number
    c_printf("%d", Code[pc+3])  -- current file number
    temp_indent = -indent
    c_stmt(", @);\n", Code[pc+2])  -- name
    CDeRefStr("_0")
    target = {-1, 1000000}
    SetBBType(Code[pc+4], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 5
end procedure
	    
procedure opAPPEND()
-- APPEND   
    integer preserve, t
    
    CRef(Code[pc+2])
    SymTab[Code[pc+2]][S_ONE_REF] = FALSE
    c_stmt("Append(&@, @, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    target = {NOVALUE, 0}
    if TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	target[MIN] = SeqLen(Code[pc+1]) + 1
    end if
    
    t = Code[pc+3]
    if t = Code[pc+1] and SymTab[t][S_MODE] = M_NORMAL then
	-- don't let this operation destroy our
	-- global idea of sequence element type
	preserve = or_type(SymTab[t][S_SEQ_ELEM_NEW], GType(Code[pc+2]))
	SetBBType(t, TYPE_SEQUENCE, target, 
		  or_type(SeqElem(Code[pc+1]), GType(Code[pc+2])))
	SymTab[t][S_SEQ_ELEM_NEW] = preserve
    else
	SetBBType(t, TYPE_SEQUENCE, target, 
		  or_type(SeqElem(Code[pc+1]), GType(Code[pc+2])))
    end if
    pc += 4
end procedure

procedure opPREPEND()
-- PREPEND
    integer preserve, t
    
    CRef(Code[pc+2])
    SymTab[Code[pc+2]][S_ONE_REF] = FALSE
    c_stmt("Prepend(&@, @, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    target = {NOVALUE, 0}
    if TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	target[MIN] = SeqLen(Code[pc+1]) + 1
    end if
    
    t = Code[pc+3]
    if t = Code[pc+1] and SymTab[t][S_MODE] = M_NORMAL then
	-- don't let this operation destroy our
	-- global idea of sequence element type
	preserve = or_type(SymTab[t][S_SEQ_ELEM_NEW], GType(Code[pc+2]))
	SetBBType(t, TYPE_SEQUENCE, target, 
		  or_type(SeqElem(Code[pc+1]), GType(Code[pc+2])))
	SymTab[t][S_SEQ_ELEM_NEW] = preserve
    else
	SetBBType(t, TYPE_SEQUENCE, target, 
		  or_type(SeqElem(Code[pc+1]), GType(Code[pc+2])))
    end if
    pc += 4
end procedure

procedure opCONCAT()
-- generate code for concatenation  
    integer t, p3, preserve
    atom j
    sequence target
	    
    if TypeIs(Code[pc+1], TYPE_OBJECT) or 
       TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt("if (IS_SEQUENCE(@) && IS_ATOM(@)) {\n", {Code[pc+1], Code[pc+2]})
    end if  
	    
    if TypeIs(Code[pc+1], {TYPE_OBJECT, TYPE_SEQUENCE}) and
       TypeIsNot(Code[pc+2], TYPE_SEQUENCE) then
	CRef(Code[pc+2])
	c_stmt("Append(&@, @, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    end if
		
    if TypeIs(Code[pc+1], TYPE_OBJECT) or 
       TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt0("}\n")
	c_stmt("else if (IS_ATOM(@) && IS_SEQUENCE(@)) {\n",
		      {Code[pc+1], Code[pc+2]})
    end if
		
    if TypeIs(Code[pc+2], {TYPE_OBJECT, TYPE_SEQUENCE}) and
       TypeIsNot(Code[pc+1], TYPE_SEQUENCE) then
	CRef(Code[pc+1])
	c_stmt("Prepend(&@, @, @);\n", {Code[pc+3], Code[pc+2], Code[pc+1]})
    end if
		
    if TypeIs(Code[pc+1], TYPE_OBJECT) or 
       TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    end if
		
    if TypeIs(Code[pc+1], TYPE_OBJECT) or 
       TypeIs(Code[pc+2], TYPE_OBJECT) or
	(TypeIs(Code[pc+1], TYPE_SEQUENCE) and 
	 TypeIs(Code[pc+2], TYPE_SEQUENCE)) or
	   (TypeIsNot(Code[pc+1], TYPE_SEQUENCE) and 
	    TypeIsNot(Code[pc+2], TYPE_SEQUENCE)) then
	c_stmt("Concat((object_ptr)&@, @, (s1_ptr)@);\n", 
		       {Code[pc+3], Code[pc+1], Code[pc+2]})  
    end if
		
    if TypeIs(Code[pc+1], TYPE_OBJECT) or 
       TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt0("}\n")
    end if
    
    target = {0, 0}
    -- compute length of result
    if TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_ATOM}) and
       TypeIs(Code[pc+2], {TYPE_SEQUENCE, TYPE_ATOM}) then
	if TypeIs(Code[pc+1], TYPE_ATOM) then
	    target[MIN] = 1
	else 
	    target[MIN] = SeqLen(Code[pc+1])
	end if
	if target[MIN] != NOVALUE then
	    if TypeIs(Code[pc+2], TYPE_ATOM) then
		target[MIN] += 1
	    else 
		j = SeqLen(Code[pc+2])
		if j = NOVALUE then
		    target[MIN] = NOVALUE
		else
		    target[MIN] += j
		end if
	    end if
	end if
	    
    else 
	target[MIN] = NOVALUE
	    
    end if
		
    if TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	j = SeqElem(Code[pc+1])
    else         
	j = GType(Code[pc+1])    
    end if       
    if TypeIs(Code[pc+2], TYPE_SEQUENCE) then
	t = SeqElem(Code[pc+2])
    else
	t = GType(Code[pc+2])
    end if               
    
    p3 = Code[pc+3]
    if p3 = Code[pc+1] and SymTab[p3][S_MODE] = M_NORMAL then
	-- don't let this operation affect our
	-- global idea of sequence element type
	preserve = or_type(SymTab[p3][S_SEQ_ELEM_NEW], t)
	SetBBType(p3, TYPE_SEQUENCE, target, or_type(j, t))
	SymTab[p3][S_SEQ_ELEM_NEW] = preserve
    
    elsif p3 = Code[pc+2] and SymTab[p3][S_MODE] = M_NORMAL then
	-- don't let this operation affect our
	-- global idea of sequence element type
	preserve = or_type(SymTab[p3][S_SEQ_ELEM_NEW], j)
	SetBBType(p3, TYPE_SEQUENCE, target, or_type(j, t))
	SymTab[p3][S_SEQ_ELEM_NEW] = preserve
    
    else    
	SetBBType(p3, TYPE_SEQUENCE, target, or_type(j, t))
    
    end if

    pc += 4
end procedure
	    
procedure opCONCAT_N()
-- concatenate 3 or more items
    n = Code[pc+1]
    c_stmt0("{\n")
    c_stmt0("int concat_list[")
    c_printf("%d];\n\n", n)
		
    t = TYPE_NULL
    for i = 0 to n-1 do
	c_stmt0("concat_list[")
	c_printf("%d] = ", i)
	CName(Code[pc+2+i])
	c_puts(";\n")
	if TypeIs(Code[pc+2+i], TYPE_SEQUENCE) then
	    t = or_type(t, SeqElem(Code[pc+2+i]))
	else    
	    t = or_type(t, GType(Code[pc+2+i])) 
	end if
    end for
    c_stmt("Concat_N((object_ptr)&@, concat_list", Code[pc+n+2])  
    c_printf(", %d);\n", n)
    c_stmt0("}\n")
    SetBBType(Code[pc+n+2], TYPE_SEQUENCE, novalue, t)
    pc += n+3
end procedure
	    
procedure opREPEAT()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = Repeat(@, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    SymTab[Code[pc+1]][S_ONE_REF] = FALSE
    CDeRefStr("_0")
    if TypeIs(Code[pc+2], TYPE_INTEGER) then
	target[MIN] = ObjValue(Code[pc+2])
	SetBBType(Code[pc+3], TYPE_SEQUENCE, target, GType(Code[pc+1]))
    else 
	SetBBType(Code[pc+3], TYPE_SEQUENCE, novalue, GType(Code[pc+1]))
    end if
    pc += 4
end procedure

procedure opDATE()
    CDeRef(Code[pc+1])  -- Code[pc+1] not used in next expression
    c_stmt("@ = Date();\n", Code[pc+1])
    target[MIN] = 8
    SetBBType(Code[pc+1], TYPE_SEQUENCE, target, TYPE_INTEGER)
    pc += 2
end procedure

procedure opTIME()
    CDeRef(Code[pc+1]) -- Code[pc+1] not used in next expression
    c_stmt("@ = NewDouble(current_time());\n", Code[pc+1])
    SetBBType(Code[pc+1], TYPE_DOUBLE, novalue, TYPE_OBJECT)
    pc += 2
end procedure

procedure opSPACE_USED() -- #ifdef EXTRA_STATS or HEAP_CHECK
    CSaveStr("_0", Code[pc+1], 0, 0, 0)
    c_stmt("@ = bytes_allocated;\n", Code[pc+1])
    CDeRefStr("_0")
    SetBBType(Code[pc+1], TYPE_INTEGER, novalue, TYPE_OBJECT)
    pc += 2
end procedure

procedure opPOSITION()
    c_stmt("Position(@, @);\n", {Code[pc+1], Code[pc+2]})
    pc += 3
end procedure
	    
procedure opEQUAL()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("if (@ == @)\n", {Code[pc+1], Code[pc+2]})
    c_stmt("@ = 1;\n", Code[pc+3])
    c_stmt("else if (IS_ATOM_INT(@) && IS_ATOM_INT(@))\n", 
			 {Code[pc+1], Code[pc+2]})
    c_stmt("@ = 0;\n", Code[pc+3])
    c_stmt0("else\n")
    c_stmt("@ = (compare(@, @) == 0);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    target = {0, 1}
    SetBBType(Code[pc+3], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 4
end procedure
		
procedure opCOMPARE()
    -- OPTIMIZE THIS SOME MORE - IMPORTANT FOR SORTING
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("if (IS_ATOM_INT(@) && IS_ATOM_INT(@))\n", {Code[pc+1], Code[pc+2]})
    c_stmt("@ = (@ < @) ? -1 : ", {Code[pc+3], Code[pc+1], Code[pc+2]})
    temp_indent = -indent
    c_stmt("(@ > @);\n", {Code[pc+1], Code[pc+2]})
    c_stmt0("else\n")
    c_stmt("@ = compare(@, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    target = {-1, 1}
    SetBBType(Code[pc+3], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 4
end procedure

procedure opFIND()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = find(@, @);\n", 
	   {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    target = {0, MAXLEN}
    SetBBType(Code[pc+3], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 4
end procedure

procedure opFIND_FROM() -- extra 3rd atom arg
    CSaveStr("_0", Code[pc+4], Code[pc+1], Code[pc+2], Code[pc+3])
    c_stmt("@ = find_from(@, @, @);\n", 
	   {Code[pc+4], Code[pc+1], Code[pc+2], Code[pc+3]})
    CDeRefStr("_0")
    target = {0, MAXLEN}
    SetBBType(Code[pc+4], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 5
end procedure

procedure opMATCH()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = e_match(@, @);\n", 
	   {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    target = {0, MAXLEN}
    SetBBType(Code[pc+3], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 4
end procedure

procedure opMATCH_FROM()
    CSaveStr("_0", Code[pc+4], Code[pc+1], Code[pc+2], Code[pc+3])
    c_stmt("@ = e_match_from(@, @, @);\n", 
	   {Code[pc+4], Code[pc+1], Code[pc+2], Code[pc+3]})
    CDeRefStr("_0")
    target = {0, MAXLEN}
    SetBBType(Code[pc+4], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 5
end procedure
	
procedure opPEEK()
-- PEEK / PEEK4U / PEEK4S   
    
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+1])
    end if
		
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	if Code[pc] = PEEK then
	    seg_peek1(Code[pc+2], Code[pc+1], 0)
	else 
	    seg_peek4(Code[pc+2], Code[pc+1], 0)
			
	    -- FIX: in first BB we might assume TYPE_INTEGER, value 0
	    -- so CName will output a 0 instead of the var's name
	    SetBBType(Code[pc+2], GType(Code[pc+2]), novalue, TYPE_OBJECT)
			
	    if Code[pc] = PEEK4S then
		c_stmt("if (@ < MININT || @ > MAXINT)\n", 
			      {Code[pc+2], Code[pc+2]})
		c_stmt("@ = NewDouble((double)(long)@);\n", 
			      {Code[pc+2], Code[pc+2]})
		    
	    else  -- PEEK4U */
		c_stmt("if ((unsigned)@ > (unsigned)MAXINT)\n", 
			      Code[pc+2])
		c_stmt("@ = NewDouble((double)(unsigned long)@);\n", 
			      {Code[pc+2], Code[pc+2]})
	    end if
	end if
    end if
		
    if TypeIs(Code[pc+1], TYPE_ATOM) then
	c_stmt0("}\n")
	c_stmt("else {\n", Code[pc+1])
	    
    elsif TypeIs(Code[pc+1], TYPE_OBJECT) then
	c_stmt0("}\n")
	c_stmt("else if (IS_ATOM(@)) {\n", Code[pc+1])
    end if
		
    if TypeIsNot(Code[pc+1], {TYPE_INTEGER, TYPE_SEQUENCE}) then
	if Code[pc] = PEEK then
	    seg_peek1(Code[pc+2], Code[pc+1], 1)
	else 
	    seg_peek4(Code[pc+2], Code[pc+1], 1)
	    SetBBType(Code[pc+2], GType(Code[pc+2]), novalue, TYPE_OBJECT)
	    if Code[pc] = PEEK4S then
		c_stmt("if (@ < MININT || @ > MAXINT)\n", 
			    {Code[pc+2], Code[pc+2]})
		c_stmt("@ = NewDouble((double)(long)@);\n", 
			    {Code[pc+2], Code[pc+2]})
	    else  -- PEEK4U */ 
		c_stmt("if ((unsigned)@ > (unsigned)MAXINT)\n", 
			    Code[pc+2])
		c_stmt("@ = NewDouble((double)(unsigned long)@);\n", 
			    {Code[pc+2], Code[pc+2]})
	    end if
	end if
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
    end if
		
    if TypeIs(Code[pc+1], TYPE_OBJECT) then
	c_stmt0("else {\n")
    end if  
	    
    if TypeIs(Code[pc+1], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	-- sequence {start, length} */
	c_stmt("_1 = (int)SEQ_PTR(@);\n", Code[pc+1])
	if Code[pc] = PEEK then
	    c_stmt0("poke_addr = (unsigned char *)get_pos_int(\"peek\", *(((s1_ptr)_1)->base+1));\n")
	else 
	    c_stmt0("peek4_addr = (unsigned long *)get_pos_int(\"peek4s/peek4u\", *(((s1_ptr)_1)->base+1));\n")
	end if
	c_stmt0("_2 = get_pos_int(\"peek\", *(((s1_ptr)_1)->base+2));\n")
	c_stmt("poke4_addr = (unsigned long *)NewS1(_2);\n", Code[pc+2])
	c_stmt("@ = MAKE_SEQ(poke4_addr);\n", Code[pc+2])
	c_stmt0("poke4_addr = (unsigned long *)((s1_ptr)poke4_addr)->base;\n")
		    
	if sequence(dj_path) then
	    if Code[pc] = PEEK then  
		c_stmt0("if ((unsigned)poke_addr <= LOW_MEMORY_MAX) {\n")
	    else
		c_stmt0("if ((unsigned)peek4_addr <= LOW_MEMORY_MAX) {\n")
	    end if
	    c_stmt0("while (--_2 >= 0) {\n")  -- SLOW WHILE
	    c_stmt0("poke4_addr++;\n")
	    if Code[pc] = PEEK then
		c_stmt0("*(int *)poke4_addr = _farpeekb(_go32_info_block.selector_for_linear_memory, (unsigned)(poke_addr++));\n")
	    else 
		c_stmt0("_1 = _farpeekl(_go32_info_block.selector_for_linear_memory, (unsigned)(peek4_addr++));\n")
		if Code[pc] = PEEK4S then
		    c_stmt0("if (_1 < MININT || _1 > MAXINT)\n")
		    c_stmt0("_1 = NewDouble((double)(long)_1);\n")
		else  -- PEEK4U 
		    c_stmt0("if ((unsigned)_1 > (unsigned)MAXINT)\n")
		    c_stmt0("_1 = NewDouble((double)(unsigned long)_1);\n")
		end if
		c_stmt0("*(int *)poke4_addr = _1;\n")
	    end if
	    c_stmt0("}\n")
	    c_stmt0("}\n")
	    c_stmt0("else {\n")
	end if
		    
	c_stmt0("while (--_2 >= 0) {\n")  -- FAST WHILE
	c_stmt0("poke4_addr++;\n")
	if Code[pc] = PEEK then
	    c_stmt0("*(int *)poke4_addr = *poke_addr++;\n")
	else 
	    c_stmt0("_1 = (int)*peek4_addr++;\n")
	    if Code[pc] = PEEK4S then
		c_stmt0("if (_1 < MININT || _1 > MAXINT)\n")
		c_stmt0("_1 = NewDouble((double)(long)_1);\n")
	    else  -- PEEK4U */
		c_stmt0("if ((unsigned)_1 > (unsigned)MAXINT)\n")
		c_stmt0("_1 = NewDouble((double)(unsigned long)_1);\n")
	    end if
	    c_stmt0("*(int *)poke4_addr = _1;\n")
	end if
	c_stmt0("}\n")
		    
	if sequence(dj_path) then 
	    c_stmt0("}\n")
	end if
    end if
	       
    if TypeIs(Code[pc+1], TYPE_OBJECT) then
	c_stmt0("}\n")
    end if
		
    CDeRefStr("_0")
		
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_DOUBLE}) then
	if Code[pc] = PEEK then
	    target = {0, 255}
	    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
	else
	    SetBBType(Code[pc+2], TYPE_ATOM, novalue, TYPE_OBJECT)
	end if
	       
    elsif TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	if Code[pc] = PEEK then 
	    SetBBType(Code[pc+2], TYPE_SEQUENCE, novalue, TYPE_INTEGER)
	else    
	    SetBBType(Code[pc+2], TYPE_SEQUENCE, novalue, TYPE_ATOM)
	end if
    else 
	-- TYPE_OBJECT */
	SetBBType(Code[pc+2], TYPE_OBJECT, novalue, TYPE_OBJECT)
	    
    end if

    pc += 3
end procedure
	
procedure opPOKE()
-- generate code for poke and poke4
-- should optimize constant address 
    
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    end if  
	    
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	if Code[pc] = POKE4 then
	    c_stmt("poke4_addr = (unsigned long *)@;\n", Code[pc+1])
	else
	    c_stmt("poke_addr = (unsigned char *)@;\n", Code[pc+1])
	end if
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("else\n")
    end if
	    
    if TypeIsNot(Code[pc+1], {TYPE_INTEGER, TYPE_SEQUENCE}) then
	if Code[pc] = POKE4 then
	    c_stmt("poke4_addr = (unsigned long *)(unsigned long)(DBL_PTR(@)->dbl);\n", 
			   Code[pc+1])
	else
	    c_stmt("poke_addr = (unsigned char *)(unsigned long)(DBL_PTR(@)->dbl);\n", 
			   Code[pc+1])
	end if
    end if
		
    if TypeIs(Code[pc+2], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@)) {\n", Code[pc+2])
    end if
		
    if TypeIs(Code[pc+2], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	if Code[pc] = POKE4 then
	    seg_poke4(Code[pc+2], 0)
	else
	    seg_poke1(Code[pc+2], 0)
	end if
    end if

    if TypeIs(Code[pc+2], TYPE_ATOM) then
	c_stmt0("}\n")
	c_stmt0("else {\n")
    elsif TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt0("}\n")
	c_stmt("else if (IS_ATOM(@)) {\n", Code[pc+2])
    end if
		
    if TypeIsNot(Code[pc+2], {TYPE_INTEGER, TYPE_SEQUENCE}) then
	if Code[pc] = POKE4 then
	    seg_poke4(Code[pc+2], 1)
	else
	    seg_poke1(Code[pc+2], 1)
	end if
    end if
		
    if TypeIs(Code[pc+2], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("}\n")
    end if
		
    if TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt0("else {\n")
    end if
		
    if TypeIs(Code[pc+2], {TYPE_SEQUENCE, TYPE_OBJECT}) then
	c_stmt("_1 = (int)SEQ_PTR(@);\n", Code[pc+2])
	c_stmt0("_1 = (int)((s1_ptr)_1)->base;\n")
		    
	if sequence(dj_path) then
	    if Code[pc] = POKE4 then
		c_stmt0("if ((unsigned)poke4_addr <= LOW_MEMORY_MAX) {\n")
	    else
		c_stmt0("if ((unsigned)poke_addr <= LOW_MEMORY_MAX) {\n")
	    end if
		    
	    c_stmt0("while (1) {\n")  -- SLOW WHILE
	    c_stmt0("_1 += 4;\n")
	    c_stmt0("_2 = *((int *)_1);\n")
	    c_stmt0("if (IS_ATOM_INT(_2))\n")
	    if Code[pc] = POKE4 then
		c_stmt0("_farpokel(_go32_info_block.selector_for_linear_memory, (unsigned long)(poke4_addr++), (unsigned long)_2);\n")
	    else
		c_stmt0("_farpokeb(_go32_info_block.selector_for_linear_memory, (unsigned long)(poke_addr++), (unsigned char)_2);\n")
	    end if
	    c_stmt0("else if (_2 == NOVALUE)\n")
	    c_stmt0("break;\n")
	    c_stmt0("else\n")
	    if Code[pc] = POKE4 then
		c_stmt0("_farpokel(_go32_info_block.selector_for_linear_memory, (unsigned long)(poke4_addr++), (unsigned long)DBL_PTR(_2)->dbl);\n")
	    else    
		c_stmt0("_farpokeb(_go32_info_block.selector_for_linear_memory, (unsigned long)(poke_addr++), (unsigned char)DBL_PTR(_2)->dbl);\n")
	    end if
	    c_stmt0("}\n")
	    c_stmt0("}\n")
	    c_stmt0("else {\n")
	end if
		    
	c_stmt0("while (1) {\n") -- FAST WHILE 
	c_stmt0("_1 += 4;\n")
	c_stmt0("_2 = *((int *)_1);\n")
	c_stmt0("if (IS_ATOM_INT(_2))\n")
	if Code[pc] = POKE4 then
	    c_stmt0("*(int *)poke4_addr++ = (unsigned long)_2;\n")
	else
	    c_stmt0("*poke_addr++ = (unsigned char)_2;\n")
	end if
	c_stmt0("else if (_2 == NOVALUE)\n")
	c_stmt0("break;\n")
	c_stmt0("else {\n")
	if Code[pc] = POKE4 then
	    if EWINDOWS and atom(bor_path) and atom(wat_path) then
		-- work around an Lcc bug
		c_stmt0("_0 = (unsigned long)DBL_PTR(_2)->dbl;\n")
		c_stmt0("*(int *)poke4_addr++ = (unsigned long)_0;\n")
	    else
		c_stmt0("*(int *)poke4_addr++ = (unsigned long)DBL_PTR(_2)->dbl;\n")
	    end if
	else    
	    if EWINDOWS and atom(bor_path) and atom(wat_path) then
		-- work around an Lcc bug
		c_stmt0("_0 = (signed char)DBL_PTR(_2)->dbl;\n")
		c_stmt0("*poke_addr++ = (signed char)_0;\n")
	    else
		c_stmt0("*poke_addr++ = (signed char)DBL_PTR(_2)->dbl;\n")
	    end if
	end if
	c_stmt0("}\n")
	c_stmt0("}\n")
		    
	if sequence(dj_path) then
	    c_stmt0("}\n")
	end if
    end if
		
    if TypeIs(Code[pc+2], TYPE_OBJECT) then
	c_stmt0("}\n")
    end if

    pc += 3
end procedure

procedure opMEM_COPY()
    c_stmt("memory_copy(@, @, @);\n", {Code[pc+1], Code[pc+2], Code[pc+3]})
    pc += 4
end procedure
	    
procedure opMEM_SET()
    c_stmt("memory_set(@, @, @);\n", {Code[pc+1], Code[pc+2], Code[pc+3]})
    pc += 4
end procedure
	    
procedure opPIXEL()
    c_stmt("Pixel(@, @);\n", {Code[pc+1], Code[pc+2]})
    pc += 3
end procedure
	    
procedure opGET_PIXEL()
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    c_stmt("@ = Get_Pixel(@);\n", {Code[pc+2], Code[pc+1]})
    CDeRefStr("_0")
    if TypeIs(Code[pc+1], TYPE_SEQUENCE) then
	if SeqLen(Code[pc+1]) = 2 then
	    target = {0, 255}
	    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
	elsif SeqLen(Code[pc+1]) = 3 then
	    SetBBType(Code[pc+2], TYPE_SEQUENCE, novalue, TYPE_INTEGER)
	else
	    SetBBType(Code[pc+2], TYPE_OBJECT, novalue, TYPE_OBJECT)
	end if
    else
	SetBBType(Code[pc+2], TYPE_OBJECT, novalue, TYPE_OBJECT)
    end if
    pc += 3
end procedure
	  
procedure opCALL()
    c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    c_stmt("_0 = (int)@;\n", Code[pc+1])
    c_stmt0("else\n")
    c_stmt("_0 = (int)(unsigned long)(DBL_PTR(@)->dbl);\n", Code[pc+1])
    c_stmt0("(*(void(*)())_0)();\n")
    pc += 2
end procedure

procedure opSYSTEM()
    c_stmt("system_call(@, @);\n", {Code[pc+1], Code[pc+2]})
    pc += 3
end procedure
		
procedure opSYSTEM_EXEC()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = system_exec_call(@, @);\n", 
	    {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    -- probably 0..255, but we can't be totally sure
    SetBBType(Code[pc+3], TYPE_INTEGER, novalue, TYPE_OBJECT)
    pc += 4
end procedure
		
-- start of I/O routines */

procedure opOPEN()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = EOpen(@, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    target = {-1, 100000}
    SetBBType(Code[pc+3], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 4
end procedure

procedure opCLOSE()
-- CLOSE / ABORT
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    end if  
	    
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	if Code[pc] = ABORT then 
	    c_stmt("UserCleanup(@);\n", Code[pc+1])
	else
	    c_stmt("EClose(@);\n", Code[pc+1])
	end if
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("else\n")
    end if
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	if Code[pc] = ABORT then 
	    c_stmt("UserCleanup((int)DBL_PTR(@)->dbl);\n", Code[pc+1])
	else
	    c_stmt("EClose((int)DBL_PTR(@)->dbl);\n", Code[pc+1])
	end if
    end if
    pc += 2
end procedure

procedure opGETC()
-- read a character from a file 
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    c_stmt("if (@ != last_r_file_no) {\n", Code[pc+1])
    c_stmt("last_r_file_ptr = which_file(@, EF_READ);\n", Code[pc+1])
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then 
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    end if  
	    
    c_stmt("last_r_file_no = @;\n", Code[pc+1])
		
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	c_stmt0("else\n")
	c_stmt0("last_r_file_no = NOVALUE;\n")
    end if
	    
    c_stmt0("}\n")
    if not EDOS then
	c_stmt0("if (last_r_file_ptr == xstdin) {\n")
	if EWINDOWS then
	    c_stmt0("show_console();\n")
	end if              
	c_stmt0("if (in_from_keyb) {\n")
	if ELINUX then
	    if EGPM then
		c_stmt("@ = mgetch(1);\n", Code[pc+2])  -- echo the character
	    else               
		-- c_stmt("@ = getch(1);\n", Code[pc+2])   -- echo the character
		c_stmt("@ = getc(xstdin);\n", Code[pc+2])   -- echo the character
	    end if              
	else               
	    c_stmt("@ = wingetch();\n", Code[pc+2])
	end if
	c_stmt0("}\n")
	c_stmt0("else\n")

	-- don't bother with mygetc() - it might not be portable
	-- to other DOS C compilers
	c_stmt("@ = getc(last_r_file_ptr);\n", Code[pc+2])
		
	c_stmt0("}\n")
	c_stmt0("else\n")
    end if              
    c_stmt("@ = getc(last_r_file_ptr);\n", Code[pc+2])
		
    CDeRefStr("_0")
    target = {-1, 255}
    SetBBType(Code[pc+2], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 3
end procedure
 
procedure opGETS()
-- read a line from a file
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    c_stmt("@ = EGets(@);\n", {Code[pc+2], Code[pc+1]})   
    CDeRefStr("_0")
    SetBBType(Code[pc+2], TYPE_OBJECT, novalue, TYPE_INTEGER) -- N.B.
    pc += 3
end procedure

procedure opGET_KEY()
-- read an immediate key (if any) from the keyboard or return -1 
    if not EDOS and EWINDOWS then
	c_stmt0("show_console();\n")
    end if
    CSaveStr("_0", Code[pc+1], 0, 0, 0)
    c_stmt("@ = get_key(0);\n", Code[pc+1])
    CDeRefStr("_0")
    target = {-1, 1000}
    SetBBType(Code[pc+1], TYPE_INTEGER, target, TYPE_OBJECT)
    pc += 2
end procedure

procedure opCLEAR_SCREEN()
    c_stmt0("ClearScreen();\n")
    pc += 1
end procedure

procedure opPUTS()
    c_stmt("EPuts(@, @);\n", {Code[pc+1], Code[pc+2]})
    pc += 3
end procedure

procedure opPRINT()
-- PRINT / QPRINT             
    if Code[pc] = QPRINT then
	c_stmt("StdPrint(@, @, 1);\n", {Code[pc+1], Code[pc+2]})
    else
	c_stmt("StdPrint(@, @, 0);\n", {Code[pc+1], Code[pc+2]})
    end if
    pc += 3
end procedure

procedure opPRINTF()
    c_stmt("EPrintf(@, @, @);\n", {Code[pc+1], Code[pc+2], Code[pc+3]})
    pc += 4
end procedure

constant DOING_SPRINTF = -9999999

procedure opSPRINTF()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = EPrintf(" & sprintf("%d", DOING_SPRINTF) & ", @, @);\n", 
	   {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    SetBBType(Code[pc+3], TYPE_SEQUENCE, novalue, TYPE_INTEGER)
    pc += 4
end procedure

procedure opCOMMAND_LINE()
    CSaveStr("_0", Code[pc+1], 0, 0, 0)
    c_stmt("@ = Command_Line();\n" , Code[pc+1])
    CDeRefStr("_0")
    SetBBType(Code[pc+1], TYPE_SEQUENCE, novalue, TYPE_SEQUENCE)
    pc += 2
end procedure

procedure opGETENV()
    CSaveStr("_0", Code[pc+2], 0, 0, 0)
    c_stmt("@ = EGetEnv(@);\n", {Code[pc+2], Code[pc+1]})
    CDeRefStr("_0")
    SetBBType(Code[pc+2], TYPE_OBJECT, novalue, TYPE_INTEGER) -- N.B.
    pc += 3
end procedure

procedure opMACHINE_FUNC()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = machine(@, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    target = machine_func_type(Code[pc+1])
    SetBBType(Code[pc+3], target[1], target[2], 
	      machine_func_elem_type(Code[pc+1]))
    pc += 4
end procedure

procedure opMACHINE_PROC()
    c_stmt("machine(@, @);\n", {Code[pc+1], Code[pc+2]})
    pc += 3
end procedure
	 
procedure opC_FUNC()
    -- not available under DOS, but better to leave it in
    -- [3] not used
    CSaveStr("_0", Code[pc+4], Code[pc+2], Code[pc+1], 0)
    c_stmt("@ = call_c(1, @, @);\n", {Code[pc+4], Code[pc+1], Code[pc+2]})
    SymTab[Code[pc+4]][S_ONE_REF] = FALSE  
    -- in elsif opcode = it's a sequence returned by Euphoria .dll
    CDeRefStr("_0")
		
    NewBB(1, E_ALL_EFFECT, 0) -- Windows call-back to Euphoria routine could occur
		
    SetBBType(Code[pc+4], TYPE_OBJECT, -- might be call to Euphoria routine
	      novalue, TYPE_OBJECT)
    pc += 5
end procedure
	    
procedure opC_PROC()
    if not EDOS then             
	c_stmt("call_c(0, @, @);\n", {Code[pc+1], Code[pc+2]})
    end if              
    -- [3] not used
    NewBB(1, E_ALL_EFFECT, 0) -- Windows call-back to Euphoria routine could occur
    pc += 4
end procedure
	  
procedure opTRACE()
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("if (IS_ATOM_INT(@))\n", Code[pc+1])
    end if  
	    
    if TypeIs(Code[pc+1], {TYPE_INTEGER, TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt("TraceOn = @;\n", Code[pc+1])
    end if
		
    if TypeIs(Code[pc+1], {TYPE_ATOM, TYPE_OBJECT}) then
	c_stmt0("else\n")
    end if  
	    
    if TypeIsNot(Code[pc+1], TYPE_INTEGER) then
	c_stmt("TraceOn = DBL_PTR(@)->dbl != 0.0;\n", Code[pc+1])
    end if
    pc += 2
end procedure
	    
	-- other tracing/profiling ops - ignored by compiler 
procedure opPROFILE()
-- PROFILE / DISPLAY_VAR / ERASE_PRIVATE_NAMES / ERASE_SYMBOL
    pc += 2
end procedure
	    
procedure opUPDATE_GLOBALS()
    pc += 1
end procedure


-- Multitasking ops

boolean tasks_created
tasks_created = FALSE

procedure dll_tasking()
    if dll_option then
	CompileErr("Multitasking operations are not supported in a .dll or .so")
    end if
end procedure

procedure opTASK_CREATE()
    dll_tasking()
    CSaveStr("_0", Code[pc+3], Code[pc+1], Code[pc+2], 0)
    c_stmt("@ = task_create(@, @);\n", {Code[pc+3], Code[pc+1], Code[pc+2]})
    CDeRefStr("_0")
    SetBBType(Code[pc+3], TYPE_DOUBLE, novalue, TYPE_OBJECT) -- always TYPE_DOUBLE
    tasks_created = TRUE
    pc += 4 
end procedure

procedure opTASK_SCHEDULE()
    dll_tasking()
    c_stmt("task_schedule(@, @);\n", {Code[pc+1], Code[pc+2]})
    pc += 3 
end procedure

procedure opTASK_YIELD()
    dll_tasking()
    c_stmt0("task_yield();\n")
    pc += 1 
end procedure

procedure opTASK_SELF()
    dll_tasking()
    CDeRef(Code[pc+1]) -- Code[pc+1] not used in next expression
    c_stmt("@ = NewDouble(tcb[current_task].tid);\n", {Code[pc+1]})
    SetBBType(Code[pc+1], TYPE_DOUBLE, novalue, TYPE_OBJECT) -- always TYPE_DOUBLE
    pc += 2 
end procedure

procedure opTASK_SUSPEND()
    dll_tasking()
    c_stmt("task_suspend(@);\n", {Code[pc+1]})
    pc += 2 
end procedure

procedure opTASK_LIST()
    dll_tasking()
    CDeRef(Code[pc+1]) -- Code[pc+1] not used in next expression
    c_stmt("@ = task_list();\n", {Code[pc+1]})
    SetBBType(Code[pc+1], TYPE_SEQUENCE, novalue, TYPE_DOUBLE)
    pc += 2 
end procedure

procedure opTASK_STATUS()
    dll_tasking()
    CSaveStr("_0", Code[pc+2], Code[pc+1], 0, 0)
    c_stmt("@ = task_status(@);\n", {Code[pc+2], Code[pc+1]})
    CDeRefStr("_0")
    SetBBType(Code[pc+2], TYPE_INTEGER, {-1,+1}, TYPE_OBJECT)
    pc += 3 
end procedure

procedure opTASK_CLOCK_STOP()
    dll_tasking()
    c_stmt0("task_clock_stop();\n")
    pc += 1 
end procedure

procedure opTASK_CLOCK_START()
    dll_tasking()
    c_stmt0("task_clock_start();\n")
    pc += 1
end procedure

sequence operation -- routine ids for all opcode handlers

global procedure init_opcodes()
-- initialize routine id's for opcode handlers
    sequence name
    
    operation = repeat(-1, length(opnames))
    for i = 1 to length(opnames) do
	name = opnames[i]
	-- some similar ops are handled by a common routine
	if find(name, {"ASSIGN_OP_SUBS", "PASSIGN_OP_SUBS",
		       "RHS_SUBS_CHECK", "RHS_SUBS_I"}) then
	    name = "RHS_SUBS"
	elsif equal(name, "NOPWHILE") then
	    name = "NOP1"
	elsif equal(name, "WHILE") then
	    name = "IF"
	elsif equal(name, "SEQUENCE_CHECK") then
	    name = "ATOM_CHECK" 
	elsif find(name, {"ASSIGN_SUBS_CHECK", "ASSIGN_SUBS_I", 
			  "PASSIGN_SUBS"}) then
	    name = "ASSIGN_SUBS"
	elsif equal(name, "PLENGTH") then
	    name = "LENGTH"
	elsif find(name, {"ELSE", "ENDWHILE"}) then
	    name = "EXIT"
	elsif equal(name, "PLUS1_I") then
	    name = "PLUS1"
	elsif equal(name, "PRIVATE_INIT_CHECK") then
	    name = "GLOBAL_INIT_CHECK"
	elsif find(name, {"LHS_SUBS1", "LHS_SUBS1_COPY"}) then
	    name = "LHS_SUBS"
	elsif equal(name, "PASSIGN_OP_SLICE") then
	    name = "ASSIGN_OP_SLICE"
	elsif equal(name, "PASSIGN_SLICE") then
	    name = "ASSIGN_SLICE"
	elsif equal(name, "PLUS_I") then
	    name = "PLUS"
	elsif equal(name, "MINUS_I") then
	    name = "MINUS"
	elsif equal(name, "SC1_AND_IF") then
	    name = "SC1_AND"
	elsif equal(name, "SC1_OR_IF") then
	    name = "SC1_OR"
	elsif equal(name, "SC2_AND") then
	    name = "SC2_OR"
	elsif equal(name, "FOR_I") then
	    name = "FOR"
	-- assume only these two ENDFORs are emitted by the front end
	elsif equal(name, "ENDFOR_INT_UP1") then
	    name = "ENDFOR_GENERAL"
	elsif equal(name, "CALL_FUNC") then
	    name = "CALL_PROC"
	elsif find(name, {"PEEK4U", "PEEK4S"}) then
	    name = "PEEK"
	elsif equal(name, "POKE4") then
	    name = "POKE"
	elsif equal(name, "ABORT") then
	    name = "CLOSE"
	elsif equal(name, "QPRINT") then
	    name = "PRINT"
	elsif find(name, {"DISPLAY_VAR", "ERASE_PRIVATE_NAMES", 
			  "ERASE_SYMBOL"}) then
	    name = "PROFILE"
	elsif find(name, {"ENDFOR_INT_UP", "ENDFOR_UP", "SC2_NULL", 
			  "ENDFOR_DOWN", "ENDFOR_INT_DOWN1", "ASSIGN_SUBS2", "PLATFORM",
			  "ENDFOR_INT_DOWN",
			  "END_PARAM_CHECK", "NOP2"}) then 
	    -- never emitted
	    name = "INTERNAL_ERROR" 
	end if
	
	operation[i] = routine_id("op" & name)
	if operation[i] = -1 then
	    InternalErr("no routine id for op" & name)
	end if
    end for
end procedure

procedure do_exec(integer start_pc)
-- generate code, starting at pc 
    pc = start_pc
    in_loop = {}
    label_map = {}
    all_done = FALSE
    while not all_done do 
	previous_previous_op = previous_op
	previous_op = opcode
	opcode = Code[pc]
	-- default some vars
	target_type = TYPE_OBJECT
	target_val = novalue      -- integer value or sequence length
	target_elem = TYPE_OBJECT -- seqeunce element type
	atom_type = TYPE_ATOM
	intcode2 = ""
	dblfn = ""
	intcode_extra = ""
	call_proc(operation[opcode], {})
    end while
end procedure       

global procedure Execute(symtab_index proc)
-- top level executor 
    
    CurrentSub = proc
    Code = SymTab[CurrentSub][S_CODE]
    
    do_exec(1)
    
    indent = 0
    temp_indent = 0
end procedure

Execute_id = routine_id("Execute")

constant hex_chars = "0123456789ABCDEF"

function hex_char(integer c)
-- return hex escape sequence for a char
    
    return "\\x" & hex_chars[1+floor(c/16)] & hex_chars[1+remainder(c, 16)]
end function

without warning
global procedure BackEnd(atom ignore)
-- Translate the IL into C 
    integer w
    symtab_index tp
    sequence string, init_name
    integer c, tp_count
    object xterm
    boolean use_hex
    
    close(c_code)
    emit_c_output = FALSE
    
    slist = s_expand(slist)
    
    -- Perform Multiple Passes through the IL

    Pass = 1
    while Pass < LAST_PASS do
	-- no output to .c files 
	main_temps()
	
	-- walk through top-level, gathering type info
	Execute(TopLevelSub)
	
	-- walk through user-defined routines, gathering type info
	GenerateUserRoutines()
	
	DeclareRoutineList() -- forces routine_id target 
			     -- parameter type info to TYPE_OBJECT
	
	PromoteTypeInfo()    -- at very end after each FULL pass: 
			      -- promotes seq_elem_new, arg_type_new 
			      -- for all symbols
			      -- sets U_DELETED, resets nrefs
	Pass += 1
    end while
    
    -- Now, actually emit the C code */
    emit_c_output = TRUE
    
    c_code = open("main-.c", "w")
    if c_code = -1 then
	CompileErr("Can't open main-.c for output\n")
    end if
    
    version()
    
    if EDOS then
	if sequence(dj_path) then
	    c_puts("#include <go32.h>\n")
	end if
    end if
    c_puts("#include <time.h>\n")
    c_puts("#include \"")
    c_puts(eudir)
    if ELINUX then
	c_puts("/include/euphoria.h\"\n")
	c_puts("#include <unistd.h>\n")
    else
	c_puts("\\include\\euphoria.h\"\n")
    end if  
    if sequence(bor_path) then
	c_puts("#include <float.h>\n")
    end if  
    c_puts("#include \"main-.h\"\n\n")
    c_puts("int Argc;\n")
    c_hputs("extern int Argc;\n")
    
    c_puts("char **Argv;\n")
    c_hputs("extern char **Argv;\n")

    if EWINDOWS then
	c_puts("unsigned default_heap;\n")
	if sequence(wat_path) or sequence(bor_path) then
	    c_puts("__declspec(dllimport) unsigned __stdcall GetProcessHeap(void);\n")
	else
	    c_puts("unsigned __stdcall GetProcessHeap(void);\n")
	end if
    end if  

    if EDJGPP then
	c_hputs("extern __Go32_Info_Block _go32_info_block;\n")
    end if
    
    c_puts("unsigned long *peek4_addr;\n")
    c_hputs("extern unsigned long *peek4_addr;\n")
    
    c_puts("unsigned char *poke_addr;\n")
    c_hputs("extern unsigned char *poke_addr;\n")
    
    c_puts("unsigned long *poke4_addr;\n")
    c_hputs("extern unsigned long *poke4_addr;\n")
    
    c_puts("struct d temp_d;\n")
    c_hputs("extern struct d temp_d;\n")
    
    c_puts("double temp_dbl;\n")
    c_hputs("extern double temp_dbl;\n")
    
    c_puts("char *stack_base;\n")
    c_hputs("extern char *stack_base;\n")

    if total_stack_size = -1 then
	-- user didn't set the option
	if tasks_created then
	    total_stack_size = (1016 + 8) * 1024 
	else
	    total_stack_size = (248 + 8) * 1024
	end if
    end if
    if EDOS and sequence(dj_path) then
	c_printf("unsigned _stklen=%d;\n", total_stack_size)
    end if
    c_printf("int total_stack_size = %d;\n", total_stack_size)
    c_hputs("extern int total_stack_size;\n")

    if EXTRA_CHECK then
	c_hputs("extern long bytes_allocated;\n")
    end if

    if EWINDOWS then
	if dll_option then
	    if sequence(wat_path) then
		c_stmt0("\nint __stdcall _CRT_INIT (int, int, void *);\n")
		c_stmt0("\n")
	    end if
	    c_stmt0("\nvoid EuInit()\n")  -- __declspec(dllexport) __stdcall 
	else 
	    if sequence(bor_path) and con_option then
		c_stmt0("\nvoid main(int argc, char *argv[])\n")
	    else
		c_stmt0("\nvoid __stdcall WinMain(void *hInstance, void *hPrevInstance, char *szCmdLine, int iCmdShow)\n")
	    
	    end if
	end if
    
    elsif ELINUX then
	if dll_option then
	    c_stmt0("\nvoid _init()\n")
	else
	    c_stmt0("\nvoid main(int argc, char *argv[])\n")
	end if
    
    else   
	-- EDOS
	c_stmt0("\nvoid main(int argc, char *argv[])\n")
    
    end if  
    c_stmt0("{\n")

    main_temps()
    
    if EWINDOWS then
	if dll_option then
	    c_stmt0("\nArgc = 0;\n")
	    c_stmt0("default_heap = GetProcessHeap();\n")
	    --c_stmt0("Backlink = bl;\n")
	else 
	    if sequence(bor_path) and con_option then
		c_stmt0("void *hInstance;\n\n")
		c_stmt0("hInstance = 0;\n")
	    else    
		c_stmt0("int argc;\n")
		c_stmt0("char **argv;\n\n")
	    end if
	    if sequence(bor_path) then
		c_stmt0("_control87(MCW_EM,MCW_EM);\n")
	    end if
	    c_stmt0("default_heap = GetProcessHeap();\n")
	    if sequence(bor_path) and con_option then
		c_stmt0("Argc = argc;\n")
		c_stmt0("Argv = argv;\n")
	    else    
		c_stmt0("argc = 1;\n")
		c_stmt0("Argc = 1;\n")
		c_stmt0("argv = make_arg_cv(szCmdLine, &argc);\n")
	    end if
	    c_stmt0("winInstance = hInstance;\n")
	end if
    
    elsif ELINUX then
	if dll_option then
	    c_stmt0("\nArgc = 0;\n")
	else   
	    c_stmt0("Argc = argc;\n")
	    c_stmt0("Argv = argv;\n")
	end if
    
    else   
	-- EDOS
	c_stmt0("Argc = argc;\n")
	c_stmt0("Argv = argv;\n")
    end if
    
    if not dll_option then
	c_stmt0("stack_base = (char *)&_0;\n")
    end if
    
    -- fail safe mechanism in case 
    -- Complete Edition library gets out by mistake
    if EWINDOWS then
	if atom(wat_path) then
	    c_stmt0("eu_startup(_00, _01, 1, (int)CLOCKS_PER_SEC, (int)CLOCKS_PER_SEC);\n")
	else
	    c_stmt0("eu_startup(_00, _01, 1, (int)CLOCKS_PER_SEC, (int)CLK_TCK);\n")  
	end if
    else
	c_puts("#ifdef CLK_TCK\n")
	c_stmt0("eu_startup(_00, _01, 1, (int)CLOCKS_PER_SEC, (int)CLK_TCK);\n")
	c_puts("#else\n")
	c_stmt0("eu_startup(_00, _01, 1, (int)CLOCKS_PER_SEC, (int)sysconf(_SC_CLK_TCK));\n")
	c_puts("#endif\n")
    end if  
    
    c_stmt0("init_literal();\n")
    
    if not dll_option then
	c_stmt0("shift_args(argc, argv);\n")
    end if
    
    -- Final walk through top-level code, constant and var initializations,
    -- outputing code

    Execute(TopLevelSub)
    
    indent = 4
    
    if dll_option then
	c_stmt0(";\n")
    else
	c_stmt0("Cleanup(0);\n")
    end if
    
    c_stmt0("}\n")

    if EWINDOWS then
	if dll_option then
	    c_stmt0("\n")
	    if atom(bor_path) then
		-- Lcc and WATCOM seem to need this instead 
		-- (Lcc had __declspec(dllexport))
		c_stmt0("int __stdcall LibMain(int hDLL, int Reason, void *Reserved)\n")
	    else 
		c_stmt0("int __declspec (dllexport) __stdcall DllMain(int hDLL, int Reason, void *Reserved)\n")
	    end if
	    c_stmt0("{\n")
	    c_stmt0("if (Reason == 1)\n")
	    c_stmt0("EuInit();\n")
	    c_stmt0("return 1;\n")
	    c_stmt0("}\n")
	end if
    end if

    -- Final walk through user-defined routines, generating C code
    start_emake()
    
    GenerateUserRoutines()  -- needs init_name_num
    
    close(c_code)
    
    c_code = open("init-.c", "a")
    if c_code = -1 then
	CompileErr("Can't open init-.c for append\n")
    end if
    
    -- declare all *used* constants, and local and global variables as ints

    -- writing to init-.c
    
    DeclareFileVars()
    DeclareRoutineList()
    DeclareNameSpaceList()
    
    c_stmt0("void init_literal()\n{\n")
    
    -- initialize the (non-integer) literals
    tp = literal_init
    c_stmt0("extern double sqrt();\n")
    
    tp_count = 0
    
    while tp != 0 do
	
	if tp_count > INIT_CHUNK then
	    -- close current .c and start a new one
	    c_stmt0("init_literal")
	    c_printf("%d();\n", init_name_num)
	    c_stmt0("}\n")
	    init_name = sprintf("init-%d", init_name_num)
	    new_c_file(init_name)
	    c_stmt0("init_literal")
	    c_printf("%d()\n", init_name_num)
	    c_stmt0("{\n")
	    c_stmt0("extern double sqrt();\n")
	    init_name_num += 1
	    tp_count = 0
	end if
	
	c_stmt0("_")
	
	if atom(SymTab[tp][S_OBJ]) then -- can't be NOVALUE
	    -- double
	    c_printf("%d = NewDouble((double)", SymTab[tp][S_TEMP_NAME])
	    c_printf8(SymTab[tp][S_OBJ])
	    c_puts(");\n")
	else 
	    -- string 
	    c_printf("%d = NewString(\"", SymTab[tp][S_TEMP_NAME])
	    -- output the string sequence one char at a time with escapes
	    string = SymTab[tp][S_OBJ]
	    
	    use_hex = FALSE
	    for elem = 1 to length(string) do
		if (string[elem] < 32 or string[elem] > 127) and 
		   not find(string[elem], "\n\t\r") then
		    use_hex = TRUE
		end if
	    end for
	    
	    if use_hex then
		-- must use hex in whole string or C might get confused
		for elem = 1 to length(string) do
		    c_puts(hex_char(string[elem]))
		    if remainder(elem, 15) = 0 and elem < length(string) then
			c_puts("\"\n\"") -- start a new string chunk, 
					 -- avoid long line
		    end if
		end for
	    else
		for elem = 1 to length(string) do
		    c = string[elem]
		    if c = '\t' then
			c_puts("\\t")
		    elsif c = '\n' then
			c_puts("\\n")
		    elsif c = '\r' then
			c_puts("\\r")
		    elsif c = '\"' then
			c_puts("\\\"")
		    elsif c = '\\' then
			c_puts("\\\\")
		    else 
			c_putc(c)
		    end if
		end for
	    end if
	    c_puts("\");\n")
	end if
	tp = SymTab[tp][S_NEXT]
	tp_count += 1
    end while
    
    c_stmt0("}\n")
    
    c_hputs("extern int TraceOn;\n")
    c_hputs("extern object_ptr rhs_slice_target;\n")
    c_hputs("extern s1_ptr *assign_slice_seq;\n")
    c_hputs("extern object last_r_file_no;\n")
    c_hputs("extern void *last_r_file_ptr;\n")
    c_hputs("extern int in_from_keyb;\n")
    c_hputs("extern void *xstdin;\n")
    c_hputs("extern struct tcb *tcb;\n")
    c_hputs("extern int current_task;\n")
    if EWINDOWS then
	c_hputs("extern void *winInstance;\n\n")
    end if  
    
    close(c_code)
    close(c_h)

    finish_emake()
    
    screen_output(STDERR, sprintf("\n%d .c files were created.\n", cfile_count+2))
    if ELINUX then
	if dll_option then
	    screen_output(STDERR, "To build your shared library, type: ./emake\n")
	else    
	    screen_output(STDERR, "To build your executable file, type: ./emake\n")
	end if
    else
	if dll_option then
	    screen_output(STDERR, "To build your .dll file, type: emake\n")
	else
	    screen_output(STDERR, "To build your .exe file, type: emake\n")
	end if
    end if

end procedure

global procedure OutputIL()
-- not used
end procedure
