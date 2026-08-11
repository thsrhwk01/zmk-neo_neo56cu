Neo65 CU ZMK Windows 안전 플래셔
================================

지원 대상
---------
Qwertykeys Neo65 CU 유선(Wired) PCB 중 MCU 마킹이 STM32F072CBT6인 기판
전용입니다. Tri-mode PCB, 기존 Neo65, Neo65 Core Plus, Neo65 Sonic HE+ 및
다른 MCU/리비전에는 사용하지 마십시오.

이 ZIP은 2026-08-11 실기기에서 플래시·readback·키 입력·Caps Lock LED·ROM DFU
복구 경로를 확인한 SHA-256의 펌웨어만 허용합니다. BIN이나 검증 해시 파일을
임의로 바꾸면 플래셔가 기록 전에 중단합니다.

사용 방법
---------
1. ZIP의 파일을 모두 같은 폴더에 압축 해제합니다. ZIP 안에서 직접 실행하지
   마십시오.
2. flash-neo65cu.cmd를 더블 클릭합니다.
3. 대상이 Neo65 CU 유선 PCB이고 MCU가 STM32F072CBT6인지 확인한 뒤 경고창에서
   Yes를 클릭합니다. No를 클릭하면 장치를 읽거나 쓰지 않고 취소합니다.
4. 다음 방법 중 하나로 STM32 system-ROM DFU에 진입합니다.
   - USB를 분리하고 Esc를 누른 채 다시 연결한 다음 Esc에서 손을 뗍니다.
   - ZMK 실행 중 Esc + Delete + Left Ctrl + Right Arrow를 동시에 누릅니다.
5. 플래셔는 정확히 한 개의 0483:df11 장치에서 다음 descriptor를 모두 확인한
   뒤 USB path와 serial을 고정합니다.
   - alt 0: @Internal Flash /0x08000000/064*0002Kg
   - alt 1: @Option Bytes /0x1FFFF800/01*016 e
6. 기존 main flash 128 KiB를 backups 폴더에 먼저 저장합니다. 백업 또는 길이
   확인이 실패하면 펌웨어를 기록하지 않습니다.
7. 검증된 BIN을 alt 0의 0x08000000에 기록하고, 같은 길이를 다시 읽어
   SHA-256이 일치하는지 확인합니다.
8. Flash and byte-for-byte readback verification complete가 표시된 뒤 USB를
   분리하고 Esc를 누르지 않은 상태로 다시 연결합니다.

플래셔는 자동 재부팅(:leave)을 요청하지 않습니다. 성공 뒤 USB를 직접 분리했다가
다시 연결하는 것이 정상 절차입니다.

부트로더 및 Option Bytes 안전
-----------------------------
STM32F072 공장 USB DFU 부트로더는 main flash가 아니라 읽기 전용 system ROM
0x1FFFC800에 있습니다. 이 플래셔는 애플리케이션 main flash의 alt 0,
0x08000000만 기록합니다. alt 1 Option Bytes를 선택하거나 mass erase 명령을
사용하지 않습니다.

다음 작업은 절대 하지 마십시오.
- dfu-util에서 -a 1 선택
- 0x1FFFF800 Option Bytes 기록
- mass erase 또는 option-byte 변경
- 0483:df11이라는 이유만으로 다른 STM32 기판을 연결한 채 진행

0483:df11 장치가 둘 이상 연결되어 있거나 descriptor가 검증값과 다르면 플래셔는
자동으로 대상을 고르지 않고 중단합니다.

처음 연결했는데 장치를 열지 못하는 경우
----------------------------------------
Windows에서는 0483:df11 DFU 인터페이스에 WinUSB 드라이버를 최초 한 번 연결해야
할 수 있습니다.

1. https://zadig.akeo.ie/ 에서 Zadig을 받습니다.
2. Options > List All Devices를 선택합니다.
3. Neo65 CU를 DFU로 진입시킨 직후 나타난 USB ID 0483:df11 장치만 선택합니다.
4. 대상 드라이버를 WinUSB로 선택하고 Install Driver를 누릅니다.
5. 플래셔를 다시 실행합니다.

0483:df11이 아닌 장치나 관계없는 STM32 장치의 드라이버는 변경하지 마십시오.

자동 백업
---------
기록 전에 다음 두 파일이 ZIP을 푼 폴더의 backups 하위에 생성됩니다.

- neo65cu-mainflash-backup-날짜-시간.bin (정확히 131,072 bytes)
- 같은 이름의 .sha256.txt

두 파일을 외장 드라이브나 다른 컴퓨터에도 복사하십시오. 저장소 개발자가 가진
원본 복구 파일은 저작권과 기판별 상태 때문에 Release ZIP에 포함하지 않습니다.

포함 파일
---------
- neo65cu-zmk.bin: 이 Actions 실행에서 빌드되고 실기기 검증 해시와 대조된 ZMK
- flash-neo65cu.cmd / flash-neo65cu.ps1: 검증·백업·플래시·readback 스크립트
- HARDWARE-VALIDATED-SHA256.txt: Release가 허용하는 실기기 검증 BIN 해시
- dfu-util.exe / libusb-1.0.dll: dfu-util 0.11 Windows x64
- SHA256SUMS.txt: 포함된 핵심 파일의 SHA-256
- BUILD-INFO.txt: source commit과 GitHub Actions run
- LICENSE.txt: 이 저장소의 MIT license
- third-party/dfu-util: dfu-util/libusb 라이선스 안내와 대응 소스
