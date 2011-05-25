library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library grlib;
use grlib.amba.all;
use grlib.stdlib.all;
use grlib.devices.all;

library techmap;
use techmap.gencomp.all;

entity idct2d is
	generic (
		ahbndx  : integer := 0;
		ahbaddr : integer := 0;
		addrmsk : integer := 16#fff#;
		verid   : integer := 0;
		irq_no  : integer := 0
	);

	port(
		rst	 : in  std_ulogic;
		clk	 : in  std_ulogic;
		ahbsi   : in  ahb_slv_in_type;
		ahbso   : out ahb_slv_out_type
	);
end entity idct2d;

architecture rtl of idct2d is
	constant hconfig : ahb_config_type := (
	  0	  => ahb_device_reg (VENDOR_NCTU, NCTU_IDCT, 0, verid, irq_no),
	  4	  => ahb_membar(ahbaddr, '1', '0', addrmsk),
	  others => X"00000000"
	);

	-- AMBA bus control signals
	signal wr_valid : std_logic; -- is the logic selected by a master
	signal haddr : std_logic_vector(7 downto 0);
	
	-----------------------------------------------------------------
	-- 1-D IDCT signals
	-----------------------------------------------------------------
	type state is (read_f, idct_1d, write_p, ready, stage0, stage1);

	signal prev_substate, next_substate: state;
	signal prev_state, next_state: state;
	
	signal stage : std_logic_vector(1 downto 0);
	signal stage_counter: std_logic_vector(2 downto 0);
	signal action : std_logic;
	
	-----------------------------------------------------------------
	-- IDCT
	-----------------------------------------------------------------
	component idct is
		port(
		rst, clk: in std_logic;
		Fin : in std_logic_vector(15 downto 0);
		pout : out std_logic_vector(15 downto 0);
		rw: in std_logic;
		rw_stage : in std_logic_vector(2 downto 0);
		action_in: in std_logic;
		done:	out std_logic
    );
	end component idct;
	
	signal rw : std_logic;
	signal rw_stage : std_logic_vector(2 downto 0);
	signal Fin, pout: std_logic_vector(15 downto 0);
	signal action_idct, idct_done : std_logic;

	-----------------------------------------------------------------
	-- BRAM
	-----------------------------------------------------------------
	component BRAM
	port(
		CLK: in std_logic;
		WE: in std_logic;
		Addr: in std_logic_vector(5 downto 0);
		Data_In: in std_logic_vector(15 downto 0);
		Data_Out: out std_logic_vector(15 downto 0)
	);
	end component;

	signal iram_addr1: std_logic_vector(5 downto 0);
	signal iram_we1	: std_logic;
	signal iram_di1 : std_logic_vector(15 downto 0);
	signal iram_do1 : std_logic_vector(15 downto 0);
	signal tram_addr1: std_logic_vector(5 downto 0);
	signal tram_we1	: std_logic;
	signal tram_do1 : std_logic_vector(15 downto 0);
	
	signal hwrite_stage : std_logic_vector(1 downto 0);
	signal hread_stage : std_logic_vector(1 downto 0);
	signal read_data : std_logic_vector(15 downto 0);
	
	signal read_count : std_logic_vector(3 downto 0);
	signal row_index : std_logic_vector(6 downto 0);
	signal col_index : std_logic_vector(5 downto 0);
begin

	ahbso.hresp   <= "00";
	ahbso.hsplit  <= (others => '0');
	ahbso.hirq	<= (others => '0');
	ahbso.hcache  <= '0';
	ahbso.hconfig <= hconfig;
	ahbso.hindex  <= ahbndx;

	iram : BRAM
	port map (
		CLK		=> clk,
		Addr	=> iram_addr1,
		WE		=> iram_we1,
		Data_In	=> iram_di1,
		Data_Out	=> iram_do1
	);
	
	tram : BRAM
	port map (
		CLK		=> clk,
		Addr	=> tram_addr1,
		WE		=> tram_we1,
		Data_In	=> pout,
		Data_Out	=> tram_do1
	);
	
	my_idct_1d : idct
	port map (
		rst, clk, 
		Fin, pout,
		rw, rw_stage,
		action_idct,
		idct_done
	);
	
	---------------------------------------------------------------------
	--  Register File Management Begins Here
	---------------------------------------------------------------------
	-- This process handles read/write of the following registers:
	--	1. Eight 16-bit input idct coefficient registers (F0 ~ F7)
	--	2. Eight 16-bit output pixel values (p0 ~ p7)
	--	3. A 1-bit register, action, signals the execution and
	--	   completion of the IDCT logic
	--
	ready_ctrl : process (clk, rst)
	begin
		if rst = '0' then
			ahbso.hready <= '1';
		elsif rising_edge(clk ) then
			if (ahbsi.hsel(ahbndx) and ahbsi.htrans(1)) = '1' then
				-- if reading block, we need one more cycle
				if (ahbsi.haddr(7 downto 2) >= "000000" and ahbsi.haddr(7 downto 2) < "100000") then
					ahbso.hready <= '0';
				else
					ahbso.hready <= '1';
				end if;
			elsif hread_stage = "10" or hwrite_stage = "01" then
				ahbso.hready <= '1';
			end if;
		end if;
	end process;
	
	-- the wr_addr_fetch process latch the write address so that it
	-- can be used in the data fetch cycle as the destination pointer
	--
	wr_addr_fetch : process (clk, rst)
	begin
		if rst = '0' then
			haddr <= (others => '0');
			wr_valid <= '0';
		elsif rising_edge(clk) then
			if (ahbsi.hsel(ahbndx) and ahbsi.htrans(1) and
				ahbsi.hready) = '1' then
				haddr <= ahbsi.haddr(7 downto 0);
				if(ahbsi.hwrite='1')then
					wr_valid <= '1';
				end if;
			else
				wr_valid <= '0';
			end if;
		end if;
	end process;

	-- for register writing, data fetch (into registers) should happens one
	-- cycle after the address fetch process.
	--
	write_reg_process : process (clk, rst)
	begin
		if (rst = '0') then
			action <= '0';
		elsif rising_edge(clk) then
			if (prev_state = stage1 and next_state = ready) then
				action <= '0';
			end if;
			if (wr_valid = '1') then
				if haddr(7) = '1' then -- if haddr = 0x80
					action <= ahbsi.hwdata(0);
				end if;
			end if;
		end if;
	end process;
	
	process(clk, rst)
	begin
		if (rst='0') then
			hwrite_stage <= "00";
		elsif (rising_edge(clk)) then
			if (ahbsi.hsel(ahbndx) and ahbsi.htrans(1) and ahbsi.hwrite) = '1' and ahbsi.haddr(7 downto 2) < "100000" then
				hwrite_stage <= "01";
			elsif(hwrite_stage = "01")then
				hwrite_stage <= "00";
			end if;
		end if;
	end process;
	
	-- for a read operation, we must start driving the data bus
	-- as soon as the device is selected; this way, the data will
	-- be ready for fetch during next clock cycle
	--
	read_reg_process : process (clk, rst)
	begin
		if (rst = '0') then
			ahbso.hrdata <= (others => '0');
		elsif rising_edge(clk) then
			if ((ahbsi.hsel(ahbndx) and ahbsi.htrans(1) and
				ahbsi.hready and (not ahbsi.hwrite)) = '1') then
				if ahbsi.haddr(7) = '1' then	-- if haddr = 0x80
					ahbso.hrdata <= (31 downto 1 => '0') & action;
				end if;
			elsif (hread_stage = "10") then
				ahbso.hrdata <= read_data & iram_do1;
			end if;
		end if;
	end process;
	
	hread_control: process (clk, rst)
	begin
		if (rst = '0') then
			read_data <= (others => '0');
			hread_stage <= "00";
		elsif rising_edge(clk) then
			if ((ahbsi.hsel(ahbndx) and ahbsi.htrans(1) and ahbsi.hready and (not ahbsi.hwrite)) = '1') then
				if ahbsi.haddr(7) = '0' then -- ahbsi.haddr < 0x80
					hread_stage <= "01";
				end if;
			end if;
			
			if (hread_stage = "01") then
				read_data <= iram_do1;
				hread_stage <= "10";
			elsif (hread_stage = "10") then
				hread_stage <= "00";
			end if;
		end if;
	end process;

	
	---------------------------------------------------------------------
	--  Controller (Finite State Machines) Begins Here
	---------------------------------------------------------------------
	FSM: process(rst, clk)
	begin
		if (rst='0') then
			prev_state <= ready;
			prev_substate <= ready;
		elsif (rising_edge(clk)) then
			prev_state <= next_state;
			prev_substate <= next_substate;
		end if;
	end process FSM;
	
	state_control: process(prev_state, col_index, action, stage_counter)
	begin
		case prev_state is
		when ready =>
			if (action='1') then
				next_state <= stage0;
			else
				next_state <= ready;
			end if;
		when stage0 =>
			if(col_index(5 downto 3) = "111" and stage_counter = "111") then	-- if we reach the last row and column
				next_state <= stage1;
			else
				next_state <= stage0;
			end if;
		when stage1 =>
			if(col_index(5 downto 3) = "111" and stage_counter = "111") then	-- if we reach the last row and column
				next_state <= ready;
			else
				next_state <= stage1;
			end if;
		when others => 
			next_state <= ready;
		end case;
	end process state_control;
	
	sub_state_control: process(prev_substate, col_index, action, idct_done, read_count, stage_counter)
	begin
			case prev_substate is
			when ready =>
				if(action='1')then
					next_substate <= read_f;
				else
					next_substate <= ready;
				end if;
			when read_f =>
				if(read_count = "1000")then
					next_substate <= idct_1d;
				else
					next_substate <= read_f;
				end if;
			when idct_1d =>
				if(idct_done = '0')then
					next_substate <= idct_1d;
				else
					next_substate <= write_p;
				end if;
			when write_p =>
					if(col_index(5 downto 3) = "111")then		-- if col_index reach last row
						if(stage_counter = "111") then
							next_substate <= ready;
						else
							next_substate <= read_f;					-- go to read next row
						end if;
					else
						next_substate <= write_p;				-- else continue write 
					end if;
			when others => 
				next_substate <= ready;
			end case;
	end process sub_state_control;
	
	stage_counter_control: process(rst, clk)
	begin
		if (rst='0') then
			stage_counter <= "000";
		elsif (rising_edge(clk)) then
			if( prev_substate = write_p and col_index(5 downto 3) = "111" )then		-- if col_index reach last row
				if( stage_counter /= "111") then					-- if we not reach the last column
					stage_counter <= stage_counter + 1;
				elsif(prev_state = stage0 or prev_state = stage1) then
					stage_counter <= "000";
				end if;
			end if;
		end if;
	end process stage_counter_control;

	action_idct_control: process(clk, rst)
	begin
		if (rst='0') then
			action_idct <= '0';
		elsif (rising_edge(clk)) then
			if prev_substate = read_f and read_count = "0111" then
				action_idct <= '1';
			else
				action_idct <= '0';
			end if;
		end if;
	end process action_idct_control;
	
	idct1d_rw_control : process(clk, rst)
	begin
		if (rst='0') then
			rw_stage <= "000";
			rw <= '0';
		elsif (rising_edge(clk)) then
			if prev_substate = read_f and read_count < "1000" then
				rw <= '1';
			else
				rw <= '0';
			end if;
			
			case prev_substate is
			when read_F =>
				rw_stage <= read_count(2 downto 0);
			when write_p=>
				if(rw_stage < "111")then
					rw_stage <= rw_stage + 1;
				else
					rw_stage <= "000";
				end if;
			when others=>
				rw_stage <= "000";
			end case;
		end if;
	end process;

	read_count_control : process(rst, clk)
	begin
		if (rst='0') then
			read_count <= "0000";
		elsif (rising_edge(clk)) then
			if(read_count = "0000" and prev_substate = read_F) or (read_count > "0000" and read_count(3) = '0' )then
				read_count <= read_count + 1;
			else	-- else if we will read f
				read_count <= "0000";
			end if;
		end if;
	end process read_count_control;
	
	row_agu: process(rst, clk)
	begin
		if (rst='0') then
			row_index <= (others => '0');
		elsif (rising_edge(clk)) then
			if(row_index(6) = '1')then		-- if row_index = 64, next will be 0
				row_index <= (others => '0');
			elsif(prev_substate = read_f and read_count < "1000") then	-- else if we will read f
				row_index <= row_index + 1;			-- acc the row_index ( we need to assign address first, because
													-- the bram reading need one more cycle to get result )
			end if;
		end if;
	end process row_agu;
	
	col_agu: process(rst, clk)
	begin
		if (rst='0') then
			col_index <= (others => '0');
		elsif (rising_edge(clk)) then
			if(prev_substate = write_p ) then						-- if we are writing
				if(col_index(5 downto 3) < "111" ) then	
					if( rw_stage > "000" ) then
						col_index <= col_index + 8;							-- set the next col_index
					end if;
				elsif(col_index(2 downto 0) < "111") then			-- we reach the last row
					col_index <= "000" & (col_index(2 downto 0)+1);		-- go back to first row
				else
					col_index <= (others => '0');
				end if;
			end if;
		end if;
	end process col_agu;
	---------------------------------------------------------------------
    --  Data Path Begins Here
    ---------------------------------------------------------------------
	-- for interface block ram
	iram_addr1 <= 	ahbsi.haddr(6 downto 1) when ((prev_state = ready and ahbsi.hsel(ahbndx)='1')
						 and ((hwrite_stage = "00" and ahbsi.hwrite = '1') or (hread_stage = "00" and ahbsi.hwrite = '0'))) else 	--write
					haddr(6 downto 1) + 1 when prev_state = ready and (hwrite_stage = "01" or hread_stage="01") else
					row_index(5 downto 0) when prev_state = stage0 else	--read, first write
					col_index(5 downto 0);
	
	iram_di1 <=	ahbsi.hwdata(31 downto 16) when prev_state = ready and hwrite_stage = "00" else
				ahbsi.hwdata(15 downto 0) when prev_state = ready and hwrite_stage = "01" else
				pout; 
				
	iram_we1 <= '1' when ((ahbsi.hsel(ahbndx) and ahbsi.htrans(1) and ahbsi.hready and ahbsi.hwrite) = '1' 
							and prev_state = ready and ahbsi.haddr(7) = '0') 
						or
						hwrite_stage = "01"	
						or
						(prev_state = stage1 and  prev_substate=write_p)
				else '0';

	-- for transpose block ram
	tram_addr1 <= 	col_index(5 downto 0) when prev_state = stage0 else	--write
					row_index(5 downto 0); 
	
	tram_we1 <= '1' when prev_state = stage0 and prev_substate=write_p else '0';
	
	Fin <= iram_do1 when  prev_state = stage0  else 
			tram_do1;

-- pragma translate_off
	bootmsg : report_version
	generic map ("Lab4 " & tost(ahbndx) & ": IDCT 2D Module rev 1");
-- pragma translate_on	
end rtl;