-- (c) Copyright 2007 Rapid Deployment Software - See License.txt
--
-- Euphoria 3.1
-- Symbol Table Routines

constant NBUCKETS = 2003  -- prime helps  
global sequence buckets   -- hash buckets
buckets = repeat(0, NBUCKETS)

global symtab_index object_type       -- s.t. index of object type 
global symtab_index atom_type         -- s.t. index of atom type 
global symtab_index sequence_type     -- s.t. index of sequence type 
global symtab_index integer_type      -- s.t. index of integer type 

sequence e_routine   -- sequence of symbol table pointers for routine_id
e_routine = {}

global symtab_index literal_init
literal_init = 0

sequence lastintval, lastintsym
lastintval = {}
lastintsym = {}

global integer last_sym
last_sym = 0
	 
function hashfn(sequence name) 
-- hash function for symbol table
    integer len
    integer val -- max is 268,448,190+len

    len = length(name)
    val = name[len] * 256 + name[1]*2 + len
    if len >= 4 then
	val = val * 64 + name[2]
	val = val * 64 + name[3]
    elsif len >= 3 then
	val = val * 64 + name[2]
    end if
    return remainder(val, NBUCKETS) + 1
end function

global function NewEntry(sequence name, integer varnum, integer scope, 
		  integer token, integer hashval, symtab_index samehash, 
		  symtab_index type_sym)
-- Enter a symbol into the table at the next available position 
    sequence new

    if TRANSLATE then
	new = repeat(0, SIZEOF_ROUTINE_ENTRY)
    else
	new = repeat(0, SIZEOF_VAR_ENTRY)
    end if
    
    new[S_NEXT] = 0
    new[S_NAME] = name
    new[S_SCOPE] = scope
    new[S_MODE] = M_NORMAL
    new[S_USAGE] = U_UNUSED
    new[S_FILE_NO] = current_file_no


    if TRANSLATE then
	-- initialize extra fields for Translator
	new[S_GTYPE] = TYPE_OBJECT
	new[S_GTYPE_NEW] = TYPE_NULL
    
	new[S_SEQ_ELEM] = TYPE_OBJECT
	new[S_SEQ_ELEM_NEW] = TYPE_NULL -- starting point for ORing
    
	new[S_ARG_TYPE] = TYPE_OBJECT
	new[S_ARG_TYPE_NEW] = TYPE_NULL
    
	new[S_ARG_SEQ_ELEM] = TYPE_OBJECT
	new[S_ARG_SEQ_ELEM_NEW] = TYPE_NULL
    
	new[S_ARG_MIN] = NOVALUE
	new[S_ARG_MIN_NEW] = -NOVALUE
    
	new[S_ARG_SEQ_LEN] = NOVALUE
	new[S_ARG_SEQ_LEN_NEW] = -NOVALUE
	
	new[S_SEQ_LEN] = NOVALUE
	new[S_SEQ_LEN_NEW] = -NOVALUE -- no idea yet
    
	new[S_NREFS] = 0
	new[S_ONE_REF] = TRUE          -- assume TRUE until we find otherwise
	new[S_RI_TARGET] = 0

	new[S_OBJ_MIN] = MININT
	new[S_OBJ_MIN_NEW] = -NOVALUE -- no idea yet
	
	new[S_OBJ_MAX] = MAXINT
	new[S_OBJ_MAX_NEW] = -NOVALUE -- missing from C code? (not needed)
    end if
   
    new[S_TOKEN] = token
    new[S_VARNUM] = varnum
    new[S_INITLEVEL] = -1
    new[S_VTYPE] = type_sym
    new[S_HASHVAL] = hashval
    new[S_SAMEHASH] = samehash
    new[S_OBJ] = NOVALUE -- important 
    
    -- add new symbol to the end of the symbol table
    SymTab = append(SymTab, new)
    if last_sym then
	SymTab[last_sym][S_NEXT] = length(SymTab)
    end if
    last_sym = length(SymTab)
    return last_sym
end function

constant BLANK_ENTRY = repeat(0, SIZEOF_TEMP_ENTRY)

global function tmp_alloc()
-- return SymTab index for a new temporary var/literal constant
    symtab_index new
    
    SymTab = append(SymTab, BLANK_ENTRY)
    new = length(SymTab)
    SymTab[new][S_USAGE] = T_UNKNOWN
   
    if TRANSLATE then
	SymTab[new][S_GTYPE] = TYPE_OBJECT
	SymTab[new][S_OBJ_MIN] = MININT
	SymTab[new][S_OBJ_MAX] = MAXINT
	SymTab[new][S_SEQ_LEN] = NOVALUE
	SymTab[new][S_SEQ_ELEM] = TYPE_OBJECT  -- other fields set later
	if length(temp_name_type)+1 = 8087 then
	    -- don't use _8087 - it conflicts with WATCOM
	    temp_name_type = append(temp_name_type, {0, 0})
	end if
	temp_name_type = append(temp_name_type, {TYPE_OBJECT, TYPE_NULL})
	SymTab[new][S_TEMP_NAME] = length(temp_name_type)
    end if
   
    return new
end function

function PrivateName(sequence name, symtab_index proc)
-- does name match that of a private in the current active proc?
    symtab_index s
    
    s = proc[S_NEXT] -- start at next entry
    while s and s[S_SCOPE] <= SC_PRIVATE do
	if equal(name, SymTab[s][S_NAME]) then
	    return TRUE
	end if
	s = SymTab[s][S_NEXT]
    end while
    return FALSE
end function

global procedure DefinedYet(symtab_index sym)
-- make sure sym has not been defined yet, except possibly as
-- a predefined symbol, or a global in a previous file 
    if not find(SymTab[sym][S_SCOPE], 
		{SC_UNDEFINED, SC_MULTIPLY_DEFINED, SC_PREDEF}) then
	if SymTab[sym][S_FILE_NO] = current_file_no then
	    CompileErr(sprintf("attempt to redefine %s", {SymTab[sym][S_NAME]}))
	end if
    end if
end procedure

global function name_ext(sequence s)
-- Returns the file name & extension part of a path.
-- Note: both forward slash and backslash are handled for all platforms. 
    integer i
    
    i = length(s)
    while i >= 1 and not find(s[i], "/\\:") do  
	i -= 1
    end while
    
    return s[i+1..$]
end function

constant SEARCH_LIMIT = 20 + 500 * (TRANSLATE or BIND)

global function NewStringSym(sequence s)
-- create a new temp that holds a string 
    symtab_index p, tp, prev
    integer search_count

    -- check if it exists already
    tp = literal_init
    prev = 0
    search_count = 0
    while tp != 0 do
	search_count += 1
	if search_count > SEARCH_LIMIT then  -- avoid n-squared algorithm
	    exit
	end if
	if equal(s, SymTab[tp][S_OBJ]) then
	    -- move it to first on list
	    if tp != literal_init then
		SymTab[prev][S_NEXT] = SymTab[tp][S_NEXT]
		SymTab[tp][S_NEXT] = literal_init
		literal_init = tp
	    end if
	    return tp
	end if
	prev = tp
	tp = SymTab[tp][S_NEXT]
    end while
    
    p = tmp_alloc()
    SymTab[p][S_OBJ] = s
   
    if TRANSLATE then
	SymTab[p][S_MODE] = M_TEMP    -- override CONSTANT for compile
	SymTab[p][S_GTYPE] = TYPE_SEQUENCE
	SymTab[p][S_SEQ_LEN] = length(s)
	if SymTab[p][S_SEQ_LEN] > 0 then
	    SymTab[p][S_SEQ_ELEM] = TYPE_INTEGER
	else 
	    SymTab[p][S_SEQ_ELEM] = TYPE_NULL
	end if
	c_printf("int _%d;\n", SymTab[p][S_TEMP_NAME])
	c_hprintf("extern int _%d;\n", SymTab[p][S_TEMP_NAME])
    
    else
	SymTab[p][S_MODE] = M_CONSTANT
   
    end if
   
    SymTab[p][S_NEXT] = literal_init
    literal_init = p
    return p
end function

global function NewIntSym(integer int_val)
-- New integer symbol 
-- int_val must not be too big for a Euphoria int 
    symtab_index p
    integer x
    
    x = find(int_val, lastintval) 
    if x then
	return lastintsym[x]  -- saves space, helps Translator reduce code size
	    
    else 
	p = tmp_alloc()
	SymTab[p][S_MODE] = M_CONSTANT
	SymTab[p][S_OBJ] = int_val
       
	if TRANSLATE then
	    SymTab[p][S_OBJ_MIN] = int_val
	    SymTab[p][S_OBJ_MAX] = int_val
	    SymTab[p][S_GTYPE] = TYPE_INTEGER
	end if
       
	lastintval = prepend(lastintval, int_val)
	lastintsym = prepend(lastintsym, p)
	if length(lastintval) > SEARCH_LIMIT then
	    lastintval = lastintval[1..floor(SEARCH_LIMIT/2)]
	end if
	return p
    end if
end function

global function NewDoubleSym(atom d)
-- allocate space for a new double literal value at compile-time 
    symtab_index p, tp, prev
    integer search_count
    
    -- check if it exists already
    tp = literal_init
    prev = 0
    search_count = 0
    while tp != 0 do
	search_count += 1
	if search_count > SEARCH_LIMIT then  -- avoid n-squared algorithm
	    exit
	end if
	if equal(d, SymTab[tp][S_OBJ]) then
	    -- found it
	    if tp != literal_init then
		-- move it to first on list
		SymTab[prev][S_NEXT] = SymTab[tp][S_NEXT]
		SymTab[tp][S_NEXT] = literal_init
		literal_init = tp
	    end if
	    return tp
	end if
	prev = tp
	tp = SymTab[tp][S_NEXT]
    end while
    
    p = tmp_alloc()
    SymTab[p][S_MODE] = M_CONSTANT
    SymTab[p][S_OBJ] = d
   
    if TRANSLATE then
	SymTab[p][S_MODE] = M_TEMP  -- override CONSTANT for compile
	SymTab[p][S_GTYPE] = TYPE_DOUBLE
	c_printf("int _%d;\n", SymTab[p][S_TEMP_NAME])
	c_hprintf("extern int _%d;\n", SymTab[p][S_TEMP_NAME])
    end if
   
    SymTab[p][S_NEXT] = literal_init
    literal_init = p
    return p
end function

global integer temps_allocated   -- number of temps allocated for CurrentSub 
temps_allocated = 0

global function NewTempSym()
-- allocate a new temp and link it with the list of temps
-- for the current subprogram 
    symtab_index p, q
    
    p = SymTab[CurrentSub][S_TEMPS]
    while p != 0 and SymTab[p][S_SCOPE] != FREE do
	p = SymTab[p][S_NEXT]
    end while
    
    if p = 0 then
	-- no free temps available 
	temps_allocated += 1
	p = tmp_alloc()
	SymTab[p][S_MODE] = M_TEMP
	SymTab[p][S_NEXT] = SymTab[CurrentSub][S_TEMPS]
	SymTab[CurrentSub][S_TEMPS] = p
   
    elsif TRANSLATE then
	-- found a free temp - make another with same name, 
	-- add it to the list, and "delete" the first one 
	
	-- remove p from the list 
	SymTab[p][S_SCOPE] = DELETED
	
	q = tmp_alloc()
	SymTab[q][S_MODE] = M_TEMP
	SymTab[q][S_TEMP_NAME] = SymTab[p][S_TEMP_NAME]
	SymTab[q][S_NEXT] = SymTab[CurrentSub][S_TEMPS]
	SymTab[CurrentSub][S_TEMPS] = q
	p = q
   
    end if
   
    if TRANSLATE then
	SymTab[p][S_GTYPE] = TYPE_OBJECT
	SymTab[p][S_SEQ_ELEM] = TYPE_OBJECT
    end if
   
    SymTab[p][S_OBJ] = NOVALUE
    SymTab[p][S_USAGE] = T_UNKNOWN
    SymTab[p][S_SCOPE] = IN_USE
    return p
end function

global procedure InitSymTab()
-- Initialize the Symbol Table 
    integer hashval, len
    --register symtab_index *bptr
    symtab_index s,st_index
    sequence kname
    
    for k = 1 to length(keylist) do 
	kname = keylist[k][K_NAME]
	len = length(kname)
	hashval = hashfn(kname)
	st_index = NewEntry(kname,
			    0, 
			    keylist[k][K_SCOPE], 
			    keylist[k][K_TOKEN],
			    hashval, 0, 0)
	if find(keylist[k][K_TOKEN], {PROC, FUNC, TYPE}) then
	    SymTab[st_index] = SymTab[st_index] & 
			repeat(0, SIZEOF_ROUTINE_ENTRY - 
				  length(SymTab[st_index]))         
	    SymTab[st_index][S_NUM_ARGS] = keylist[k][K_NUM_ARGS]
	    SymTab[st_index][S_OPCODE] = keylist[k][K_OPCODE]
	    SymTab[st_index][S_EFFECT] = keylist[k][K_EFFECT]
	    SymTab[st_index][S_REFLIST] = {}
	end if
	if keylist[k][K_TOKEN] = PROC then
	    if equal(kname, "_toplevel_") then
		TopLevelSub = st_index
	    end if
	elsif keylist[k][K_TOKEN] = TYPE then
	    if equal(kname, "object") then
		object_type = st_index
	    elsif equal(kname, "atom") then
		atom_type = st_index
	    elsif equal(kname, "integer") then
		integer_type = st_index
	    elsif equal(kname, "sequence") then
		sequence_type = st_index
	    end if
	end if
	if buckets[hashval] = 0 then
	    buckets[hashval] = st_index
	else 
	    s = buckets[hashval]
	    while SymTab[s][S_SAMEHASH] != 0 do 
		s = SymTab[s][S_SAMEHASH]
	    end while
	    SymTab[s][S_SAMEHASH] = st_index
	end if
    end for
    file_start_sym = length(SymTab)
end procedure

global procedure add_ref(token tok)
-- BIND only: add a reference to a symbol from the current routine
    symtab_index s
    
    s = tok[T_SYM]
    if s != CurrentSub and -- ignore self-ref's
	  not find(s,  SymTab[CurrentSub][S_REFLIST]) then
	-- new reference
	SymTab[s][S_NREFS] += 1
	SymTab[CurrentSub][S_REFLIST] &= s
    end if  
end procedure

global procedure MarkTargets(symtab_index s, integer attribute)
-- Note the possible targets of a routine id call 
    symtab_index p
    sequence sname
    sequence string
    integer colon, h
    
    if (SymTab[s][S_MODE] = M_TEMP or
	SymTab[s][S_MODE] = M_CONSTANT) and 
	sequence(SymTab[s][S_OBJ]) then
	-- hard-coded string  
	string = SymTab[s][S_OBJ] 
	colon = find(':', string)
	if colon = 0 then
	    sname = string
	else 
	    sname = string[colon+1..$]  -- ignore namespace part
	    while length(sname) and sname[1] = ' ' or sname[1] = '\t' do
		sname = sname[2..$]
	    end while   
	end if
	
	-- simple approach - mark all names in hash bucket that match, 
	-- ignoring GLOBAL/LOCAL 
	if length(sname) = 0 then
	    return
	end if
	h = buckets[hashfn(sname)]
	while h do
	    if equal(sname, SymTab[h][S_NAME]) then
		if attribute = S_NREFS then
		    if BIND then
			add_ref({PROC, h})
		    end if
		else
		    SymTab[h][attribute] += 1
		end if
	    end if
	    h = SymTab[h][S_SAMEHASH]
	end while           
    else 
	-- mark all visible routines parsed so far 
	p = SymTab[TopLevelSub][S_NEXT]
	while p != 0 do
	    if SymTab[p][S_FILE_NO] = current_file_no or
	       SymTab[p][S_SCOPE] = SC_GLOBAL then
		SymTab[p][attribute] += 1
	    end if
	    p = SymTab[p][S_NEXT]
	end while
    end if
end procedure

global sequence dup_globals

global function keyfind(sequence word, integer file_no)
-- Uses hashing algorithm to try to match 'word' in the symbol
-- table. If not found, 'word' must be a new user-defined identifier. 
-- If file_no is not -1 then file_no must match and symbol must be a GLOBAL. 
    integer hashval, scope, defined
    symtab_index st_ptr
    token tok, gtok

    dup_globals = {}
    hashval = hashfn(word)
    st_ptr = buckets[hashval] 
    
    while st_ptr do
	if equal(word, SymTab[st_ptr][S_NAME]) then
	    -- name matches 
	    
	    tok = {SymTab[st_ptr][S_TOKEN], st_ptr}
	    
	    if file_no = -1 then
		-- unqualified  
		
		-- Consider: S_PREDEF 
		
		scope = SymTab[st_ptr][S_SCOPE]
		
		if scope = SC_GLOBAL then
		    if current_file_no = SymTab[st_ptr][S_FILE_NO] then
			-- found global in current file 
		       
			if BIND then
			    add_ref(tok)
			end if
		       
			return tok
		    end if
		    -- found global in another file 
		    gtok = tok
		    dup_globals &= st_ptr               
		    -- continue looking for more globals with same name 
		
		elsif scope = SC_LOCAL then 
		    if current_file_no = SymTab[st_ptr][S_FILE_NO] then
			-- found local in current file 
		       
			if BIND then
			    add_ref(tok)
			end if
		      
			return tok
		    end if
		
		elsif scope = SC_PREDEF then
		    if length(dup_globals) = 0 then
		       
			if BIND then
			    add_ref(tok)
			end if
		       
			return tok
		    end if
		    -- else a global has overridden this symbol 
		
		else 
		       
		    if BIND then
			add_ref(tok)
		    end if
		       
		    return tok -- keyword, private
		
		end if
	    
	    else 
		-- qualified - must match global symbol in specified file 
		if file_no = SymTab[tok[T_SYM]][S_FILE_NO] and
		    SymTab[tok[T_SYM]][S_SCOPE] = SC_GLOBAL then
		       
		    if BIND then
			add_ref(tok)
		    end if
		       
		    return tok 
		end if
	    end if
	    
	    -- otherwise keep looking 
	end if 
	
	st_ptr = SymTab[st_ptr][S_SAMEHASH]
    end while
    
    if length(dup_globals) = 1 then
	-- matched exactly one global
		       
	if BIND then
	    add_ref(gtok)
	end if
		       
	return gtok
    end if
    
    -- couldn't find unique one 
    if length(dup_globals) = 0 then
	defined = SC_UNDEFINED
    else
	defined = SC_MULTIPLY_DEFINED
    end if
    tok = {VARIABLE, NewEntry(word, 0, defined, 
		       VARIABLE, hashval, buckets[hashval], 0)}
    buckets[hashval] = tok[T_SYM]
    return tok  -- no ref on newly declared symbol
end function


global procedure Hide(symtab_index s)
-- remove the visibility of a symbol
-- by deleting it from its hash chain 
    symtab_index prev, p

    p = buckets[SymTab[s][S_HASHVAL]]
    prev = 0
    while p != s and p != 0 do
	prev = p
	p = SymTab[p][S_SAMEHASH]
    end while
    if p = 0 then
	return -- already hidden 
    end if
    if prev = 0 then
	buckets[SymTab[s][S_HASHVAL]] = SymTab[s][S_SAMEHASH]
    else
	SymTab[prev][S_SAMEHASH] = SymTab[s][S_SAMEHASH]
    end if
end procedure

procedure LintCheck(symtab_index s)
-- do some lint-like checks on s 
    integer u, n
    sequence vtype, place, problem, file
    
    u = SymTab[s][S_USAGE]
    file = name_ext(file_name[current_file_no])
    
    if SymTab[s][S_SCOPE] = SC_LOCAL then
	if SymTab[s][S_MODE] = M_CONSTANT then
	    vtype = "local constant"
	else
	    vtype = "local variable"
	end if
	place = ""
    
    else  
	n = SymTab[CurrentSub][S_NUM_ARGS]
	if SymTab[s][S_VARNUM] < n then
	    vtype = "parameter"
	else
	    vtype = "private variable"
	end if
	place = SymTab[CurrentSub][S_NAME]
    
    end if
    
    problem = ""
    if u != or_bits(U_READ, U_WRITTEN) then
	if u = U_UNUSED or 
	     (u = U_WRITTEN and 
		(equal(vtype, "local constant") 
--               or equal(vtype, "parameter") -- this is rarely a real problem
		 ))
		 then
	    problem = "not used" 
	
	elsif u = U_READ then
	    problem = "never assigned a value"
	
	end if
	
	if length(problem) then
	    if length(place) then
		Warning(sprintf("%s %s in %s() in %s is %s", 
				   {vtype, SymTab[s][S_NAME], 
				   place, file, problem}))
	    else
		Warning(sprintf("%s %s in %s is %s", 
				   {vtype, SymTab[s][S_NAME], 
				   file, problem}))
	    end if
	end if
    end if
end procedure

global procedure HideLocals()
-- hide the local symbols and "lint" check them
    symtab_index s

    s = file_start_sym
    while s do 
	if SymTab[s][S_SCOPE] = SC_LOCAL and 
	   SymTab[s][S_FILE_NO] = current_file_no then
	    Hide(s)
	    if SymTab[s][S_TOKEN] = VARIABLE then
		LintCheck(s)
	    end if
	end if
	s = SymTab[s][S_NEXT]
    end while
end procedure

global procedure ExitScope()
-- delete all the private scope entries for the current routine 
-- and "lint" check them
    symtab_index s

    s = SymTab[CurrentSub][S_NEXT]
    while s and SymTab[s][S_SCOPE] = SC_PRIVATE do
	Hide(s) 
	LintCheck(s)
	s = SymTab[s][S_NEXT]
    end while 
end procedure

