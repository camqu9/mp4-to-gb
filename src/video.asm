        INCLUDE "video.inc"
        INCLUDE "utils.inc"
        INCLUDE "obj/frames.inc"
        INCLUDE "obj/sound.inc"
                

IF DEF(CONFIG) == 0
CONFIG EQU 0
ENDC

IF DEF(PULLDOWN) == 0
PULLDOWN EQU 1.0
ENDC
PULLDOWN_SKIPF EQU (((1.0 - DIV(1.0, PULLDOWN)) + 128) >> 8) & $FF

HSIZE EQU 20
IF CONFIG == 0
VSIZE EQU 9
BYTES_PER_HLINE EQU 5
ENDC
IF CONFIG == 1
VSIZE EQU 8
BYTES_PER_HLINE EQU 5
ENDC
IF CONFIG == 2
VSIZE EQU 7
BYTES_PER_HLINE EQU 4
ENDC

PACKETS_PER_VBLK EQU 36

DEF BYTES_PER_VBLANK = ((HSIZE * VSIZE) * 16 / 4) - (144 * BYTES_PER_HLINE)
IF BYTES_PER_VBLANK < 0
DEF BYTES_PER_VBLANK = 0
ENDC
DEF HLINE_PADDING = 144 * BYTES_PER_HLINE * 4 - HSIZE * VSIZE * 16
IF HLINE_PADDING < 0
DEF HLINE_PADDING = 0
ENDC
SCY_OFFSET EQU 0 - (144 - 16 * VSIZE) / 4
        
IF ((BYTES_PER_VBLANK % 4) != 0) || ((BYTES_PER_HLINE * 144) % 4 != 0)
  FAIL "BYTES_PER_VBLANK & BYTES_PER_HLINE * 144 must be multiples of 4"
ENDC

F_COMPRESSED                EQU $18
F_NOT_COMPRESSED            EQU $3E

TIMER_COUNTER_INIT          EQU $100 - (456 / 16)

FIRST_VIDEO_BANK            EQU 1
LAST_VIDEO_BANK             EQU FIRST_VIDEO_BANK + NUM_VIDEO_BANKS - 1
FIRST_AUDIO_BANK            EQU LAST_VIDEO_BANK + 1
LAST_BANK                   EQU FIRST_AUDIO_BANK + NUM_AUDIO_BANKS - 1
IF LAST_BANK >= $100
LONG_BANK                   EQU 1
ENDC
IF LAST_BANK < $80
MBC3                        EQU 1
ENDC

        SECTION "hram", HRAM
        
Cycle:                        DS 1
BankswitchPending:            DS 1      ; compressed metaframes only
PulldownCounter:              DS 1
CompressedFlagSaved:          DS 1
Trampoline:                   DS 3

DEF HBlankEntry         EQUS "(HBlank+HBlankEntryOffset)"
DEF CurVideoBankLow     EQUS "(HBlank+HBlankCurVideoBankLowOffset)"
IF DEF(LONG_BANK)
DEF CurVideoBankHigh    EQUS "(HBlank+HBlankCurVideoBankHighOffset)"
ENDC
DEF HBlankSCY           EQUS "(HBlank+HBlankSCYOffset)"
DEF CompressedFlag      EQUS "(HBlank+HBlankCompressedFlagOffset)"
DEF HBlankSelfmodJump   EQUS "(HBlank+HBlankSelfmodJumpOffset)"
DEF DeltaPacketCount    EQUS "(HBlank+HBlankDeltaPacketCountOffset)"
DEF AudioProcAddr       EQUS "(HBlank+HBlankAudioProcAddrOffset)"
DEF AudioBankLow        EQUS "(HBlank+HBlankAudioBankLowOffset)"
DEF AudioBankHigh       EQUS "(HBlank+HBlankAudioBankHighOffset)"
DEF AudioProcReturn     EQUS "(HBlank+HBlankAudioProcReturnOffset)"
DEF TimerEntry          EQUS "(HBlank+HBlankTimerEntryOffset)"

        SECTION "stack", WRAM0[$CF00]
        
        DS 256
Stack:
        
        ;  Interrupt vectors
        SECTION "ih_vbl",ROM0[$40]
        
VBlankInt:
        jp VBlank

        
        SECTION "ih_lcdc",ROM0[$48]
        
LCDCInt:     
        jr HBlankEntry   
        
        
        SECTION "ih_timer",ROM0[$50]
        
TimerInt:                        
        jp TimerEntry
        
        
        SECTION "ih_sio",ROM0[$58]
        
SerialIOInt:                        
        reti    
        
        
        SECTION "ih_joy",ROM0[$60]
        
JoypadInt:                        
        reti

        
        SECTION "header",ROM0[$100]
        
Header:                 
        nop             
        jp Initialize 
        
        DB $CE,$ED,$66,$66,$CC,$0D,$00,$0B 
        DB $03,$73,$00,$83,$00,$0C,$00,$0D 
        DB $00,$08,$11,$1F,$88,$89,$00,$0E 
        DB $DC,$CC,$6E,$E6,$DD,$DD,$D9,$99 
        DB $BB,$BB,$67,$63,$6E,$0E,$EC,$CC 
        DB $DD,$DC,$99,$9F,$BB,$B9,$33,$3E 
        
        ;   123456789012345
        DB "1BPPVIDEO",0,0,0,0,0,0
        DB $00          ;CGB flag
        DB 0,0          ;New Licensee Code
        DB 0            ;SGB flag
        IF DEF(MBC3) == 0
        DB $19          ;Cartridge type
        ELSE
        DB $11
        ENDC
        DB 0            ;ROM size
        DB 0            ;RAM size
        DB $00          ;Destination code
        DB $00          ;Licensee Code
        DB $01          ;Version number
        DB $00          ;Header checksum
        DB $00,$00      ;Global checksum
        
        
        SECTION "main_code",ROM0
        
Initialize:  
        di        
        
        ld hl,$C000        ;   Clear RAM and WRAM
        xor a              ;Clear from C000 with 00
.rambl: ld [hl+],a         ;Clear four bytes (this way is faster)
        ld [hl+],a
        ld [hl+],a
        ld [hl+],a
        bit 5,h            
        jr z,.rambl         ;If next byte address is not E000 then continue
        
        ld sp,Stack
        
        ld c,$7F
        ld hl,$FF80
.hirbl: ld [hl+],a
        dec c              ;Clear one byte
        jr nz,.hirbl       ;If 7E bytes hasn't been copied, then continue
        
        .wvblk: ld a,[$FF44]       ;Read LCDC vertical position
        cp $90
        jr nz,.wvblk       ;Loop until it is just inside VBlank
        
        xor a
        ldh [$FF40],a         ; Disable LCDC
        
        ld de,HBlank
        ld hl,HBlankTemplate
        ld bc,HBT_end - HBlankTemplate    ; Copy the HBlank procedure in HRAM
        call Copy                         ; as it is self-modifying
        
        ld a,$C3
        ldh [Trampoline],a
        
        ld a,$FF
        ld bc,16
        ld hl,$8BF0
        call Fill           ; Create a black tile for the backdrop (index $BF)       
        
        ld a,$BF
        ld bc,(32*32)*2
        ld hl,$9800
        call Fill           ; Fill all the pattern tables with the backdrop tile
        
        ld c,HSIZE
        ld b,VSIZE
        ld e,0
        ld hl,$9800
        call MakePictureRectangle3      ; Pictures 0-1 pattern table
        
        ld c,HSIZE
        ld b,VSIZE
        ld e,$C0
        ld hl,$9C00
        call MakePictureRectangle3      ; Pictures 2-3 pattern table
        
        ld hl,Frame+4                   ; Assume the first metaframe is literal
        ld de,$8000
        ld bc,(HSIZE * VSIZE) * 16 + HLINE_PADDING
        call Copy                       ; Upload pictures 0-1 with the LCDC off
        
        ld a,F_NOT_COMPRESSED
        ldh [CompressedFlag],a          ; The 2nd metaframe must also be literal
        ldh [CompressedFlagSaved],a
        
        ld bc,4                         ; Skip the second metaframe header
        add hl,bc                       ; (it must be 0,0,0,0)
        ld d,h
        ld e,l                          ; Keep the src address in DE
        ld hl,$8C00                     ; Initialize the dest address in HL
        ld bc,$4000                     ; Load the sound address in BC
        
        ld a,LOW(FIRST_VIDEO_BANK)
        ldh [CurVideoBankLow],a
        ld [$2222],a
        IF DEF(MBC3) == 0
        IF DEF(LONG_BANK)
        ld a,HIGH(FIRST_VIDEO_BANK)
        ldh [CurVideoBankHigh],a        
        ELSE
        xor a
        ENDC                            ; Initialize the bank counters & sync
        ld [$3333],a                    ; them with the MBC
        ENDC
        
        ld a,4                          ; Initialize the frame down-counter
        ldh [Cycle],a                   ; (counts for next metaframe)
        
        ; Reset the APU
        xor a
        ldh [$FF26],a
        ld a, $FF
        ldh [$FF26],a
        ; Turn all DACs on
        ldh [$FF12],a
        ldh [$FF17],a
        ldh [$FF1A],a
        ldh [$FF21],a
        ; Put all channels on both left and right
        ldh [$FF25],a
        
        ld a,$FF
        ldh [$FF47],a             ; All black palette      
        
        ld a,$91
        ldh [$FF40],a             ; LCDC on!
        
.wfvbl: ldh a,[$FF44]
        cp $95                  ; Wait one full frame because the first frame
        jr nz,.wfvbl            ; may skip one HBlank interrupt
        
        ld a,1
        ldh [$FF05],a
        ldh [$FF06],a
        ld a,%0000_0101
        ldh [$FF07],a             ; Enable timer but with a long period
        
        ld a,$CC
        ldh [$FF47],a             ; Initialize palette
        ld a,$08
        ldh [$FF41],a             ; Select HBlank as LCDC interrupt source
        ld a,%0000_0111
        ldh [$FFFF],a             ; Enable LCDC interrupts and VBL interrupts
        ld a,SCY_OFFSET
        ldh [$FF42],a             ; Scroll up a bit for creating the bars
        xor a                   ; Clear the interrupt flag (no spurious
        ldh [$FF0F],a             ; interrupts please)
        
        ei                      ; Interrupts on!

.l2:    jr .l2
        
        
NextBank:
        ldh a,[CurVideoBankLow]
        inc a
        ldh [CurVideoBankLow],a
        ld [$2222],a
        IF DEF(LONG_BANK)
        ret nz
        ldh a,[CurVideoBankHigh]
        inc a
        ldh [CurVideoBankHigh],a
        ENDC
        ret
        
        
VBlank: ld a,TIMER_COUNTER_INIT
        ldh [$FF05],a
        ldh [$FF06],a
        ei
        
        ldh a,[PulldownCounter]
        add PULLDOWN_SKIPF
        ldh [PulldownCounter],a
        jp c,.freeze_frame
        
        ldh a,[CompressedFlagSaved]
        ldh [CompressedFlag],a
        cp F_COMPRESSED             ; If this frame is compressed, go to the
        jp z,.vbl_compression       ; decompression code
        
        ld a,d
        cp ($8000 - BYTES_PER_VBLANK) >> 8
        jr c,.nobsA
        jr nz,.bsA
        ld a,($8000 - BYTES_PER_VBLANK) & $FF
        cp e
        jr nc,.nobsA
.bsA:   call NextBank
        ld de,$4000
        
.nobsA: 
        REPT BYTES_PER_VBLANK / 4
        ld a,[de]
        ld [hl+],a
        inc e
        ld a,[de]
        ld [hl+],a
        inc e
        ld a,[de]
        ld [hl+],a
        inc e
        ld a,[de]
        inc de                      ; Copy the uncompressed block via
        ENDR                        ; unrolled loop
        
        ld a,SCY_OFFSET
        ldh [$FF42],a                 
        dec a                       
        ldh [HBlankSCY],a           ; Reset the scroll and the
        ld a,$18                    ; counters used by the HBlank thread,
        ldh [HBlankSelfmodJump],a   ; for the stretch raster effect
        
        ldh a,[Cycle]
        dec a
        ldh [Cycle],a
        jp z,.nextcycle_defer_bank_sw
        
        ld a,d
        cp ($8000 - 144*BYTES_PER_HLINE) >> 8
        jr c,.nobsB
        jr nz,.bsB
        ld a,($8000 - 144*BYTES_PER_HLINE) & $FF
        cp e
        jr nc,.nobsB
.bsB:   call NextBank
        ld de,$4000
        
.nobsB: ldh a,[Cycle]
        rra
        jr c,.nochgpal
        ld a,$F0
        ldh [$FF47],a

.nochgpal:
        jp .vblank_exit
        
        
.vbl_compression:
        ld a,d
        or e                        ; Source address == 0
        jp z,.video_ended           ; => video has already ended!
        
        ldh a,[BankswitchPending]
        and a
        jr z,.c_nextpacket
        
        call NextBank
        ld de,$4000

.c_nextpacket:
        inc e
        ld a,[de]
        ldh [BankswitchPending],a ; Read the bankswitch flag in the block head
        dec e
        ld a,[de]           ; Read the packet count in the block head
        inc e
        inc e
        inc e
        inc de              ; Skip the rest of the block head
        
        and a
        jp z,.c_end         ; Empty block, skip everyting
        
        push de
        ld e,a
        ld a,PACKETS_PER_VBLK
        sub e
        swap a
        ld d,a
        and $F0
        add LOW(.c_copy)
        ldh [Trampoline+1],a
        ld a,d
        jr nc,.c_nocarry
        inc a
.c_nocarry:
        and $0F
        add HIGH(.c_copy)
        ldh [Trampoline+2],a
        pop de
        
        jp Trampoline
.c_copy:
        REPT PACKETS_PER_VBLK
        ld a,[de]
        inc e
        add l
        DB $30, 1   ;jr nc,+1
        inc h
        ld l,a
        ld a,[de]
        ld [hl+],a
        inc e
        ld a,[de]
        ld [hl+],a
        inc e
        ld a,[de]
        ld [hl+],a
        inc de          
        ENDR        ; 16 bytes per iteration!        
        
.c_end: ld a,SCY_OFFSET
        ldh [$FF42],a
        dec a
        ldh [HBlankSCY],a
        ld a,$18
        ldh [HBlankSelfmodJump],a
        
        ldh a,[BankswitchPending]
        and a
        jr z,.c_nonextbank
        
        call NextBank
        ld de,$4000
        
.c_nonextbank:
        ldh a,[Cycle]
        dec a
        ldh [Cycle],a
        jr z,.nextcycle
        
.c_nonextcycle:
        rra
        jr c,.c_nochgpal
        ld a,$F0
        ldh [$FF47],a

.c_nochgpal: 
        ld a,[de]
        ldh [DeltaPacketCount],a
        inc e
        ld a,[de]
        ldh [BankswitchPending],a
        inc e
        inc e
        inc de
        
        jp .vblank_exit
        
        
.nextcycle_defer_bank_sw:
        ldh a,[BankswitchPending]
        and a
        jr z,.nextcycle
        
        call NextBank
        ld de,$4000
        
        ; Reset the addresses for the next 4 frame upload cycle
        ; HL = source address for next metaframe
.nextcycle:
        ld a,[de]                 ; Read stop flag
        and a
        jr nz,.end_video          ; Stop flag != 0 => end the video
        inc e
        ld a,[de]                 ; Read compression flag
        ldh [CompressedFlag],a
        ldh [CompressedFlagSaved],a
        inc e
        ld a,[de]
        ldh [BankswitchPending],a
        inc e
        inc de
        
        ldh a,[CompressedFlag]
        cp F_COMPRESSED
        jr nz,.nc_nofirstcompressedpacket
        
        ld a,[de]
        inc e
        ldh [DeltaPacketCount],a
        ld a,[de]
        inc e
        ldh [BankswitchPending],a
        inc e
        inc de
        
.nc_nofirstcompressedpacket:
        ld l,0
        ld a,h
        cp $8C
        sbc a
        and $0C
        or $80
        ld h,a
        
        ld a,$CC
        ldh [$FF47],a
        ldh a,[$FF40]
        xor $18
        ldh [$FF40],a
        
        ld a,4
        ldh [Cycle],a
        
        jp .vblank_exit
        
.end_video:
        ld de,0                     ; Set the src address to zero so that we'll
                                    ; remember that we stopped
        ld bc,Silence               ; Set sound playback address to a zeroed area
        
        xor a
        ldh [DeltaPacketCount], a   ; When compression is enabled and the delta
        ld a,F_COMPRESSED           ; packet count is zero, the HBlank thread
        ldh [CompressedFlag], a     ; is idle
        ldh [CompressedFlagSaved], a
        
        jp .vblank_exit
        
        
.video_ended:
        ld a,SCY_OFFSET
        ldh [$FF42],a
        dec a
        ldh [HBlankSCY],a
        ld a,$18
        ldh [HBlankSelfmodJump],a
        
.ldc1 2 ; delay to avoid skipping frame at the beginning
        ldh a,[$FF44]
        and a
        jr z,.ldc1
        inc a
        ldh [$FF06],a                 ;Disable the frickin' timer!!
        ldh [$FF05],a
        
        jp TimerEntry
        
        
        SECTION "video_engine_template", ROM0

HBlankTemplate:
HBT_compressed:
        ldh a,[$FF44]         ; Use LY to count the packets already done
HBT_counter:                ; CompressionPacketCount - 1
        cp 255
        jr nc,HBT_endj
        
        ld a,[de]
        inc e
        add l
        ld l,a
        jr c,.carry
        REPT 2
        ld a,[de]
        ld [hl+],a
        inc e
        ENDR
        ld a,[de]
        ld [hl+],a
        inc de
        
        jr HBT_commend
    
.carry: inc h
        REPT 2
        ld a,[de]
        ld [hl+],a
        inc e
        ENDR
        ld a,[de]
        ld [hl+],a
        inc de
        
HBT_commend:  
HBT_endj:                 ; HBlankSelfmodJump
        jr HBT_end_noscroll           ; This offset must be $18
        ldh [$FF05],a
        ldh [HBlankSelfmodJump],a     ; A == $18!
        ldh a,[HBlankSCY]
        dec a
        ldh [HBlankSCY],a
HBT_exit:
HBT_TimerEntry:
        push af
HBT_AudioBankLow:
        ld a,LOW(FIRST_AUDIO_BANK)
        ld [$2222],a
        IF DEF(LONG_BANK)
HBT_AudioBankHigh:
        ld a,HIGH(FIRST_AUDIO_BANK)
        ld [$3333],a
        ENDC
HBT_AudioProcAddr:
        jp AudioFrame
        
        IF DEF(LONG_BANK)
        REPT 1                    ; Add some padding to make sure that the
        nop                       ; jump at HBT_endj has $18 as argument so that
        ENDR                      ; it becomes a ld a,$18 if it's not taken
        ELSE
        REPT 6                    ; Add some padding to make sure that the
        nop                       ; jump at HBT_endj has $18 as argument so that
        ENDR                      ; it becomes a ld a,$18 if it's not taken
        ENDC
        
HBT_end_noscroll:
        ld a,$3E
        ldh [HBlankSelfmodJump],a
        jr HBT_exit
        
HBT_AudioProcReturn:
HBT_VideoBankLow:
        ld a,$00
        ld [$2222],a
        IF DEF(LONG_BANK)
HBT_VideoBankHigh:
        ld a,$00
        ld [$3333],a
        ENDC
        pop af
        reti
        
HBT_Entry:
HBT_scy:                  ; HBlankSCY - 1
        ld a,SCY_OFFSET-1
        ldh [$FF42],a
        
HBT_cjmp:                 ; CompressedFlag
        jr HBT_compressed

HBT_notcompr: 
        IF BYTES_PER_HLINE == 5
        REPT 5
        ld a,[de]
        ld [hl+],a
        inc de
        ENDR
        ELIF BYTES_PER_HLINE == 4
        REPT 3
        ld a,[de]
        ld [hl+],a
        inc e
        ENDR
        ld a,[de]
        ld [hl+],a
        inc de
        ELSE
        REPT 3
        ld a,[de]
        ld [hl+],a
        inc de
        ENDR
        ENDC
        
        jr HBT_commend
HBT_end:  
        
RealHBlankProcSize                  EQU HBT_end - HBlankTemplate
HBlankEntryOffset                   EQU HBT_Entry - HBlankTemplate
HBlankCurVideoBankLowOffset         EQU HBT_VideoBankLow - HBlankTemplate + 1
IF DEF(LONG_BANK)
HBlankCurVideoBankHighOffset        EQU HBT_VideoBankHigh - HBlankTemplate + 1
ENDC
HBlankSCYOffset                     EQU HBT_scy - HBlankTemplate + 1
HBlankCompressedFlagOffset          EQU HBT_cjmp - HBlankTemplate
HBlankSelfmodJumpOffset             EQU HBT_endj - HBlankTemplate
HBlankDeltaPacketCountOffset        EQU HBT_counter - HBlankTemplate + 1
HBlankAudioProcAddrOffset           EQU HBT_AudioProcAddr - HBlankTemplate + 1
HBlankAudioBankLowOffset            EQU HBT_AudioBankLow - HBlankTemplate + 1
IF DEF(LONG_BANK)
HBlankAudioBankHighOffset           EQU HBT_AudioBankHigh - HBlankTemplate + 1
ENDC
HBlankAudioProcReturnOffset         EQU HBT_AudioProcReturn - HBlankTemplate
HBlankTimerEntryOffset              EQU HBT_TimerEntry - HBlankTemplate

        SECTION "video_engine", HRAM[$FFFE-RealHBlankProcSize]

HBlank:                 DS RealHBlankProcSize
        
        SECTION "audio_frame_handlers", ROM0[$0000]
       
AudioFrame:
        ld a,[bc]
        ldh [$FF24],a
        inc bc
        bit 7,b
        jr z,AudioProcReturn
        ld b,$40
        ldh a,[AudioBankLow]
        inc a
        ldh [AudioBankLow],a
        IF DEF(LONG_BANK)
        jr nz,AudioProcReturn
        ldh a,[AudioBankHigh]
        inc a
        ldh [AudioBankHigh],a
        ENDC
        jr AudioProcReturn
        
        SECTION "silence", ROM0
        
Silence: DS 400 ; double length in case of pulldown-triggered freeze-frame

      
        SECTION "data", ROM0[$4000]
        
Frame:  DB 0
        
