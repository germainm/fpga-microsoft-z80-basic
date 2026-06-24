-- bufferedUART.vhd
-- Base sur l'UART 6850-compatible de Grant Searle (2013)
-- Adapte pour horloge unique clk avec baud generator interne
-- Logique toggle txByteWritten/txByteSent (robuste, ne se coince jamais)

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.std_logic_unsigned.all;

entity bufferedUART is
    port (
        clk     : in std_logic;
        n_wr    : in  std_logic;
        n_rd    : in  std_logic;
        regSel  : in  std_logic;
        dataIn  : in  std_logic_vector(7 downto 0);
        dataOut : out std_logic_vector(7 downto 0);
        n_int   : out std_logic;
        rxClock : in  std_logic;  -- ignore (baud interne)
        txClock : in  std_logic;  -- ignore (baud interne)
        rxd     : in  std_logic;
        txd     : out std_logic;
        n_rts   : out std_logic := '0';
        n_cts   : in  std_logic;
        n_dcd   : in  std_logic
    );
end bufferedUART;

architecture rtl of bufferedUART is

    -- Baud generator: 50MHz/(115200*16)=27.13 -> 27
    constant BAUD16 : integer := 27;
    signal baud_cnt : integer range 0 to 31 := 0;
    signal baud_en  : std_logic := '0';  -- pulse a 16x baud

    type serialStateType is (idle, dataBit, stopBit);
    signal txState : serialStateType := idle;
    signal rxState : serialStateType := idle;

    signal txBitCount   : std_logic_vector(3 downto 0) := (others=>'0');
    signal txClockCount : std_logic_vector(5 downto 0) := (others=>'0');
    signal txBuffer     : std_logic_vector(7 downto 0) := (others=>'0');
    signal txByteLatch  : std_logic_vector(7 downto 0) := (others=>'0');
    signal txByteWritten: std_logic := '0';
    signal txByteSent   : std_logic := '0';

    signal rxBitCount   : std_logic_vector(3 downto 0) := (others=>'0');
    signal rxClockCount : std_logic_vector(5 downto 0) := (others=>'0');
    signal rxBuffer     : std_logic_vector(7 downto 0) := (others=>'0');
    signal rxDataReg    : std_logic_vector(7 downto 0) := (others=>'0');
    signal rxByteReceived : std_logic := '0';
    signal rxByteRead   : std_logic := '0';

    signal controlReg : std_logic_vector(7 downto 0) := (others=>'0');
    signal statusReg  : std_logic_vector(7 downto 0);

    signal rxd_s1, rxd_s2 : std_logic := '1';
    signal n_wr_d, n_rd_d : std_logic := '1';
    signal n_int_i : std_logic := '1';

begin

    -- Status: bit0=RX ready, bit1=TX empty (toggle egaux)
    statusReg(0) <= '1' when rxByteReceived /= rxByteRead else '0';
    statusReg(1) <= '1' when txByteWritten = txByteSent else '0';
    statusReg(2) <= n_dcd;
    statusReg(3) <= n_cts;
    statusReg(4) <= '0';
    statusReg(5) <= '0';
    statusReg(6) <= '0';
    statusReg(7) <= not n_int_i;

    n_int_i <= '0' when (rxByteReceived /= rxByteRead) and controlReg(7)='1' else '1';
    n_int <= n_int_i;
    n_rts <= '0';

    dataOut <= rxDataReg when regSel='1' else statusReg;

    -- Baud generator + bus + TX + RX, tout sur clk
    process(clk)
    begin
        if rising_edge(clk) then
            -- Baud 16x
            if baud_cnt = BAUD16-1 then
                baud_cnt <= 0;
                baud_en  <= '1';
            else
                baud_cnt <= baud_cnt + 1;
                baud_en  <= '0';
            end if;

            -- Sync RXD + detection fronts bus
            rxd_s1 <= rxd; rxd_s2 <= rxd_s1;
            n_wr_d <= n_wr; n_rd_d <= n_rd;

            -- ECRITURE CPU (front montant n_wr = fin, donnee stable)
            if n_wr='1' and n_wr_d='0' then
                if regSel='1' then
                    -- toggle: signale nouveau byte a envoyer
                    if txByteWritten = txByteSent then
                        txByteWritten <= not txByteWritten;
                    end if;
                    txByteLatch <= dataIn;
                else
                    controlReg <= dataIn;
                end if;
            end if;

            -- LECTURE CPU (front montant n_rd)
            if n_rd='1' and n_rd_d='0' then
                if regSel='1' then
                    -- acquittement RX: toggle
                    if rxByteReceived /= rxByteRead then
                        rxByteRead <= not rxByteRead;
                    end if;
                end if;
            end if;

            -- ============ TX (machine toggle robuste, sur baud_en) ============
            if baud_en='1' then
                case txState is
                when idle =>
                    txd <= '1';
                    if (txByteWritten /= txByteSent) then
                        txBuffer <= txByteLatch;
                        txByteSent <= not txByteSent;
                        txState <= dataBit;
                        txd <= '0';  -- start bit
                        txBitCount <= (others=>'0');
                        txClockCount <= (others=>'0');
                    end if;
                when dataBit =>
                    if txClockCount = 15 then
                        txClockCount <= (others=>'0');
                        if txBitCount = 8 then
                            txd <= '1';  -- stop bit
                            txState <= stopBit;
                        else
                            txd <= txBuffer(0);
                            txBuffer <= '0' & txBuffer(7 downto 1);
                            txBitCount <= txBitCount + 1;
                        end if;
                    else
                        txClockCount <= txClockCount + 1;
                    end if;
                when stopBit =>
                    if txClockCount = 15 then
                        txState <= idle;
                    else
                        txClockCount <= txClockCount + 1;
                    end if;
                end case;
            end if;

            -- ============ RX (sur baud_en) ============
            if baud_en='1' then
                case rxState is
                when idle =>
                    if rxd_s2 = '0' then  -- start bit detecte
                        rxState <= dataBit;
                        rxClockCount <= (others=>'0');
                        rxBitCount <= (others=>'0');
                    end if;
                when dataBit =>
                    if rxClockCount = 7 and rxBitCount = 0 then
                        -- milieu du start bit: verifier
                        if rxd_s2 = '1' then
                            rxState <= idle;  -- faux start
                        else
                            rxClockCount <= rxClockCount + 1;
                        end if;
                    elsif rxClockCount = 15 then
                        rxClockCount <= (others=>'0');
                        if rxBitCount = 8 then
                            -- tous les bits recus
                            rxDataReg <= rxBuffer;
                            if rxByteReceived = rxByteRead then
                                rxByteReceived <= not rxByteReceived;
                            end if;
                            rxState <= stopBit;
                        else
                            rxBuffer <= rxd_s2 & rxBuffer(7 downto 1);
                            rxBitCount <= rxBitCount + 1;
                        end if;
                    else
                        rxClockCount <= rxClockCount + 1;
                    end if;
                when stopBit =>
                    if rxClockCount = 15 then
                        rxState <= idle;
                    else
                        rxClockCount <= rxClockCount + 1;
                    end if;
                end case;
            end if;

        end if;
    end process;

end rtl;
