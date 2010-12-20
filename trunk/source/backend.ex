-- (c) Copyright 2007 Rapid Deployment Software - See License.txt
--
-- mini Euphoria front-end for stand-alone back-end
-- we redundantly declare some things to keep the size down
without type_check

include file.e
include machine.e
include wildcard.e
include reswords.e
include compress.e
include misc.e

----------------------------------------------------------------------
-- copied from global.e to avoid bringing in all of global.e

constant ELINUX = platform() = LINUX 
constant EBSD = 0 -- set manually to 1 on FreeBSD - see also global.e

global integer PATH_SEPARATOR, SLASH
global sequence SLASH_CHARS
if ELINUX then
    PATH_SEPARATOR = ':' -- in PATH environment variable
    SLASH = '/'          -- preferred on Linux/FreeBSD
    SLASH_CHARS =  "/"   -- special chars allowed in a path
else
    PATH_SEPARATOR = ';'
    SLASH = '\\'
    SLASH_CHARS = "\\/:"
end if

global sequence file_name
file_name = {""} -- for now

global sequence file_name_entered, warning_list
file_name_entered = ""
warning_list = {}

include pathopen.e

global sequence misc, SymTab, slist
global integer AnyTimeProfile, AnyStatementProfile, sample_size, 
	       gline_number, max_stack_per_call, il_file
il_file = 0

global sequence all_source
all_source = {} -- there is no source when we read the IL from disk

-- fields for reduced symbol table stored in IL
global constant 
    S_OBJ = 1,
    S_NEXT = 2,
    S_MODE = 3,
    S_SCOPE = 4,
    S_FILE_NO = 5,
    S_NAME = 6, 
    S_TOKEN = 7, 
    S_CODE = 8,
    S_LINETAB = 9,
    S_TEMPS = 10,
    S_NUM_ARGS = 11,
    S_FIRSTLINE = 12,
    S_STACK_SPACE = 13

global constant M_NORMAL = 1,  -- copied from global.e
		M_CONSTANT = 2,
		M_TEMP = 3,
		SC_UNDEFINED = 9

global constant SRC = 1,  -- from global.e
	       LINE = 2,
      LOCAL_FILE_NO = 3,
	    OPTIONS = 4 
----------------------------------------------------------------------

include backend.e

procedure fatal(sequence msg)
-- fatal error 
    puts(2, msg & '\n')
    puts(2, "\nPress Enter\n")
    if getc(0) then -- prompt
    end if
    abort(1)
end procedure

procedure verify_checksum(atom size, atom vchecksum)
-- check that the IL was generated by our binder, 
-- and has not been tampered with   
    atom checksum
    integer prev_c, c
    
    checksum = 11352 -- magic starting point
    size = 0
    prev_c = -1
    -- read whole IL
    while 1 do
	c = getc(current_db)
	if c = -1 then
	    exit
	end if
	
	if c < 100 then
	    if c != 'A' then
		checksum += c
	    end if
	else
	    checksum += c*2
	end if
	size -= 1
	if size = 0 then
	    exit
	end if
	prev_c = c
    end while
    
    checksum = remainder(checksum, 1000000000)
    if checksum != vchecksum then
	fatal("IL code is not in proper format")
    end if
end procedure   

procedure InputIL()
-- Read the IL into several Euphoria variables.
-- Must match OutputIL() in il.e
    integer c1, c2, start
    atom size, checksum
    
    c1 = getc(current_db)
    if c1 = '#' then
	--ignore shebang line
	if atom(gets(current_db)) then
	end if
	c1 = getc(current_db)
    end if
    
    c2 = getc(current_db) -- IL version
    if c1 != IL_MAGIC or c2 < 10 then
	fatal("not an IL file!")
    end if
    
    if c2 = 10 then
	fatal("Obsolete .il file. Please recreate it using Euphoria 3.0 later.")
    end if
    
    -- read size
    size = (getc(current_db) - 32) +
	   (getc(current_db) - 32) * 200 +
	   (getc(current_db) - 32) * 40000 +
	   (getc(current_db) - 32) * 8000000
    
    -- read checksum
    checksum = (getc(current_db) - 32) +
	       (getc(current_db) - 32) * 200 +
	       (getc(current_db) - 32) * 40000 +
	       (getc(current_db) - 32) * 8000000
    
    start = where(current_db)
    
    verify_checksum(size, checksum) -- reads rest of file
    
    -- restart at beginning
    if seek(current_db, start) != 0 then
	fatal("seek failed!")
    end if

    init_compress()
    misc = fdecompress(0)
    max_stack_per_call = misc[1]
    AnyTimeProfile = misc[2]
    AnyStatementProfile = misc[3]
    sample_size = misc[4]
    gline_number = misc[5]
    file_name = misc[6]
    
    SymTab = fdecompress(0)
    slist = fdecompress(0)
end procedure

sequence cl, filename

cl = command_line()

-- open our own .exe file
if ELINUX then
    current_db = e_path_open(cl[1], "rb")
else
    current_db = open(cl[1], "rb") 
end if

if current_db = -1 then
    fatal("Can't open .exe file")
end if

integer OUR_SIZE -- Must be less than or equal to actual backend size.
		 -- We seek to this position and then search for the marker.
		 
if platform() = DOS32 then
    OUR_SIZE = 170000 -- backend.exe (Causeway compression)

elsif ELINUX then
    if EBSD then
	-- set EBSD manually above on FreeBSD
	OUR_SIZE = 150000  -- backendu for FreeBSD (not compressed)
    else    
	OUR_SIZE = 150000  -- backendu for Linux
    end if

else
    OUR_SIZE = 67000  -- backendw.exe (upx compression)
end if

if seek(current_db, OUR_SIZE) then
    fatal("seek failed")
end if

object line

-- search for Euphoria code 
-- either tacked on the end of our .exe, 
-- or as a command-line filename

while 1 do
    line = gets(current_db)
    if atom(line) then
	-- EOF, no eu code found in our .exe
	-- see if a filename was specified on the command line
	if length(cl) > 2 and match("BACKEND", upper(cl[1])) then
	    filename = cl[3]
	    close(current_db)
	    current_db = e_path_open(filename, "rb")
	    if current_db != -1 then
		il_file = 1
		exit
	    end if
	    fatal("Couldn't open " & filename)
	end if
	fatal("no Euphoria code to execute")
    end if
    if equal(line, IL_START) then
	exit
    end if
end while

integer save_first_rand
save_first_rand = rand(1000000000)

InputIL() -- read Euphoria data structures from compressed IL 
	  -- in our own .exe file, or from a .il file, and descramble them

set_rand(save_first_rand)

BackEnd(il_file)-- convert Euphoria data structures to memory and call C back-end
