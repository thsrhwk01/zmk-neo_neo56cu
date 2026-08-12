# Neo65 CU Wired ZMK 펌웨어

[English](README.md)

STM32F072 기반 **Qwertykeys/NEO Studio Neo65 CU 유선 PCB**를 위한 커뮤니티 ZMK 펌웨어입니다. USB 전용 ZMK 포트와 STM32 공장 system-ROM 부트로더를 보존하는 Windows 안전 플래셔를 제공합니다.

> [!WARNING]
> 이 펌웨어는 **STM32F072CBT6가 실장된 Neo65 CU 유선 PCB 전용**입니다. Tri-mode PCB, 기존 Neo65, Neo65 Core Plus, Neo65 Sonic HE+, LINK65 및 다른 키보드에는 사용하지 마십시오. 플래시 전에 PCB 종류와 MCU marking을 직접 확인해야 합니다.

## 주요 기능

- STM32F072CBT6의 USB HID 키보드 지원
- QMK `LAYOUT_wired`와 동일한 70개 위치 matrix transform
- Base와 Fn 두 레이어
- PC13 active-high Caps Lock LED
- 실기기에서 확인한 세 가지 STM32 ROM DFU 진입 방법
- 펌웨어·대상·백업·readback을 검증하는 Windows 안전 플래셔
- ZMK revision 고정 및 GitHub Actions 자동 패키징
- [keymap-drawer](https://github.com/caksoylar/keymap-drawer)를 이용한 키맵 그림 자동 생성

## 지원 하드웨어

| 항목 | 지원 대상 |
| --- | --- |
| 키보드 | Qwertykeys/NEO Studio Neo65 CU |
| PCB | 유선 PCB만 지원 |
| MCU | STM32F072CBT6 |
| 연결 | USB 전용 |
| Flash/SRAM | 128 KiB / 16 KiB |

이 포트는 VIA, Vial, ZMK Studio, Bluetooth 및 2.4 GHz 무선을 지원하지 않습니다.

## 검증된 펌웨어

아래 raw BIN은 정적 감사를 통과한 뒤 2026-08-11 실제 Neo65 CU에 기록하고 같은 데이터를 다시 읽어 byte-for-byte 일치를 확인했습니다. USB 인식, 장착된 모든 스위치, Fn 레이어, Windows 키, Caps Lock LED, 애플리케이션 재시작, cold boot 및 세 가지 ROM DFU 진입 경로도 모두 통과했습니다.

| 항목 | 값 |
| --- | --- |
| source commit | `2a36f566802fbc65287ddc931ae285326bfa16f5` |
| Actions run | [#31321651375](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/runs/31321651375) |
| 파일 | `neo65cu-zmk.bin` |
| 크기 | 38,812 bytes (`0x979C`) |
| SHA-256 | `63669C31092A134764A3B9BB48FF251312EAFF1B73EDF787DABD2427C6BBF74A` |
| Initial MSP | `0x20001E18` |
| Reset Handler | `0x080024B5` |

ZIP이나 GitHub artifact digest가 아니라 압축을 푼 **raw BIN**의 해시를 비교해야 합니다. 같은 실기기 검증 절차를 통과하지 않은 다른 SHA-256의 BIN으로 대체하지 마십시오.

## Windows 빠른 설치

1. [최신 Release](https://github.com/thsrhwk01/zmk-neo_neo65cu/releases/latest)에서 `NEO65CU-ZMK-Windows.zip`을 내려받아 모든 파일을 압축 해제합니다. ZIP 안에서 직접 실행하지 마십시오.
2. `flash-neo65cu.cmd`를 더블 클릭합니다.
3. 대상이 `STM32F072CBT6`가 실장된 Neo65 CU 유선 PCB인지 확인합니다. 확인창의 기본 선택은 **No**이며, 취소하면 장치를 읽거나 쓰지 않습니다.
4. 안내가 나오면 USB를 분리하고 `Esc`를 누른 채 다시 연결한 다음 `Esc`에서 손을 뗍니다.
5. `Flash and byte-for-byte readback verification complete`가 표시될 때까지 기다립니다.
6. `Esc`를 누르지 않은 상태로 USB를 분리했다가 다시 연결합니다.

플래셔는 다음 조건을 모두 만족할 때만 기록합니다.

- BIN의 크기, initial stack pointer와 Reset Handler가 STM32F072 범위에 맞음
- 정확히 한 개의 `0483:df11` DFU 장치가 STM32F072의 예상 memory map을 노출함
- 기록 전에 전체 128 KiB main-flash 백업이 성공함
- alternate setting 0의 `0x08000000`만 선택함
- 기록 후 readback이 BIN과 byte-for-byte 일치함

기존 main flash와 체크섬은 압축을 푼 패키지의 `backups` 폴더 아래에 저장됩니다. 즉시 별도의 저장 위치에도 복사하십시오. 드라이버와 복구에 관한 자세한 설명은 패키지의 `README_KO.txt`에 있습니다.

아직 Release가 없다면 최신 성공 [Build and Release workflow](https://github.com/thsrhwk01/zmk-neo_neo65cu/actions/workflows/build.yml)에서 `NEO65CU-ZMK-Windows` artifact를 내려받을 수 있습니다.

## 수동 설치

가능하면 배포 패키지의 Windows 안전 플래셔를 사용하십시오. 수동 설치를 진행하려면 먼저 raw BIN이 정확한지 확인합니다.

```powershell
Get-FileHash .\neo65cu-zmk.bin -Algorithm SHA256
```

`Esc`를 누른 채 USB를 연결해 DFU로 진입하고 목록을 새로 조회합니다.

```powershell
dfu-util -l
```

장치가 `0483:df11`이고 다음 두 memory map을 모두 표시할 때만 계속합니다.

- alt 0: `0x08000000`부터 시작하는 internal flash, `64 × 2 KiB`
- alt 1: `0x1FFFF800`의 option bytes, `16 bytes`

같은 조회 결과에 방금 표시된 path와 serial을 사용해야 합니다. 다른 PC나 이전 실행의 값을 복사하지 마십시오. 기록 전에 main flash 전체를 백업합니다.

```powershell
$dfuPath = "방금 실행한 dfu-util -l에 표시된 path"
$dfuSerial = "방금 실행한 dfu-util -l에 표시된 serial"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x20000" `
  -U ".\neo65cu-mainflash-backup.bin"

(Get-Item .\neo65cu-mainflash-backup.bin).Length
```

백업 길이가 `131072`인지 확인한 다음, 검증된 이미지를 alt 0에만 기록하고 재부팅 전에 다시 읽어 비교합니다.

```powershell
dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000" `
  -D ".\neo65cu-zmk.bin"

dfu-util -d ",0483:df11" -p $dfuPath -S $dfuSerial `
  -a 0 -s "0x08000000:0x979C" `
  -U ".\neo65cu-zmk-readback.bin"

(Get-FileHash .\neo65cu-zmk.bin).Hash -eq `
  (Get-FileHash .\neo65cu-zmk-readback.bin).Hash
```

비교 결과가 반드시 `True`여야 합니다. USB를 분리했다가 다시 연결하면 애플리케이션이 부팅됩니다.

`-a 1`, Option Bytes 기록, mass erase, `:leave`, LINK65의 `0x08006000` 애플리케이션 주소 및 LINK65의 `1688:2220` USB ID는 절대 사용하지 마십시오.

## 키맵

키맵 원본은 [`boards/arm/neo65cu/neo65cu.keymap`](boards/arm/neo65cu/neo65cu.keymap)입니다. Fn 키는 화살표 묶음 바로 왼쪽에 있으며, 누르고 있는 동안 숫자열이 Grave와 F1–F12로 바뀝니다.

| 키 조합 | 동작 |
| --- | --- |
| Fn + `Backspace` | ZMK 애플리케이션 재시작 |
| `Esc`를 누른 채 USB 연결 | ZMK 시작 전 STM32 system-ROM DFU 진입 |
| Fn + `Delete` | ZMK 실행 중 STM32 system-ROM DFU 진입 |

![Neo65 CU 키맵 다이어그램](keymap-drawer/neo65cu.svg "keymap-drawer로 생성")

그림은 QMK `LAYOUT_wired`의 70개 논리 위치를 모두 표시합니다. 따라서 조립 방식에 따라 동시에 실장되지 않는 ISO/split optional footprint도 포함됩니다.

### 키맵 그림 자동 생성

키맵, [`config/neo65cu.json`](config/neo65cu.json) 또는 [`keymap_drawer.config.yaml`](keymap_drawer.config.yaml)을 변경해 push하면 [`draw-keymap.yml`](.github/workflows/draw-keymap.yml)이 실행됩니다. ZMK 키맵을 파싱한 뒤 갱신된 `keymap-drawer/neo65cu.yaml`과 `keymap-drawer/neo65cu.svg`를 같은 branch에 자동으로 commit합니다.

재사용 workflow는 keymap-drawer의 정확한 commit에 고정되어 있고 keymap-drawer `0.23.0`을 설치합니다. Fork에서 자동 commit이 거부되면 branch 보호 규칙을 확인한 뒤 **Settings → Actions → General → Workflow permissions → Read and write permissions**를 활성화하십시오.

## 부트로더 보존과 복구

공장 USB DFU 부트로더는 `0x1FFFC800`의 변경 불가능한 STM32 system ROM에 있습니다. 원본 애플리케이션과 이 ZMK 이미지는 모두 main flash `0x08000000`에서 시작하며, ZMK linker와 플래셔는 system ROM을 기록 대상으로 삼지 않습니다.

실제 장치는 다음 alternate setting을 노출합니다.

- alt 0: `@Internal Flash /0x08000000/064*0002Kg`
- alt 1: `@Option Bytes /0x1FFFF800/01*016 e`

Windows 플래셔는 MCU 식별을 위해 두 descriptor를 확인하지만 **alt 0만 선택**합니다. alt 1 선택, Option Bytes 변경, mass erase 및 main flash 밖의 기록은 하지 않습니다.

사용 가능한 ROM DFU 진입 방법은 다음과 같습니다.

1. `Esc`를 누른 채 USB를 연결합니다.
2. ZMK 실행 중 Fn을 누른 채 `Delete`를 누릅니다.
3. PCB가 노출된 상태에서 뒷면 미실장 `SW?` footprint의 두 패드를 쇼트한 채 USB 전원을 인가합니다.

키보드가 이미 실행 중일 때 `SW?`를 쇼트해도 아무 동작이 없었으며, 전원을 넣는 순간부터 쇼트가 유지되어야 합니다. 자석식 pogo-pin/도터보드 구조 때문에 정상 조립 상태에서는 접근하기 어려우므로 일상 복구에는 `Esc`를 사용하십시오. 다른 패드를 임의로 쇼트하거나 DFU 인식 후에도 전원이 들어온 상태로 쇼트를 계속 유지하지 마십시오.

기존 재시작·ROM DFU 다중 키 combo는 ZMK가 combo 성립 가능성을 기다리는 동안 구성 키 입력을 지연시키므로 제거했습니다. 전용 Fn 레이어 binding을 사용하면 일반 타이핑 중 해당 키에 지연이 생기지 않습니다.

Runtime ROM handoff 동작 자체는 기존 combo로 실기기 검증했습니다. 새 Fn 레이어 binding은 유일한 runtime 복구 수단으로 의존하기 전에 실기기에서 확인하십시오.

## 빌드와 Release

기본 workflow는 ZMK `v0.3.0`의 정확한 commit `edf5c0814fd3ea202e43aad2d68fd32e882a518c`에 고정되어 있습니다. LINK65 저장소와 같이 표준 ZMK build를 한 번 실행하고 raw BIN의 크기, initial MSP와 Reset Handler만 검사한 뒤 bundle checksum과 함께 패키징합니다.

Branch push, pull request와 수동 workflow 실행은 아래 두 artifact를 모두 생성합니다. Version tag는 GitHub Release도 게시합니다.

| Artifact | 내용 |
| --- | --- |
| `firmware` | 표준 ZMK workflow의 raw `neo65cu-zmk.bin` |
| `NEO65CU-ZMK-Windows` | Windows 안전 플래셔 패키지 |

`SHA256SUMS.txt`는 각 build bundle 내부 파일의 무결성을 확인합니다. Build 성공이 변경된 펌웨어의 실기기 검증을 대신하지는 않습니다.

검증을 마친 Release는 annotated version tag를 push해 게시합니다.

```console
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

Version tag는 `NEO65CU-ZMK-Windows.zip`, `neo65cu-zmk.bin`, `SHA256SUMS.txt`를 게시합니다. `v1.1.0-beta.1`처럼 문자가 포함된 tag는 prerelease로 표시됩니다.

준비된 west workspace에서는 다음과 같이 로컬 빌드할 수 있습니다.

```console
west build -s zmk/app -b neo65cu -- \
  -DZMK_CONFIG=/path/to/zmk-neo_neo65cu/config \
  -DZMK_EXTRA_MODULES=/path/to/zmk-neo_neo65cu
```

## 현재 제한

- 장착된 모든 스위치와 Fn 레이어는 확인했지만, 미실장 ISO/split optional footprint는 물리적으로 시험할 수 없었습니다.
- 정상 USB cold boot는 실기기에서 3/3회 확인했습니다.
- 설정 partition과 persistent configuration 저장 기능은 없습니다.
- VIA, Vial 및 ZMK Studio는 지원하지 않습니다.
- 유선 PCB만 지원합니다.

전체 bring-up, ROM handoff와 실기기 검증 과정은
[한국어 포팅 가이드](docs/porting-guide_ko.md)와
[영문 포팅 가이드](docs/porting-guide.md)에 정리했습니다. 시간순 근거 기록은
[`dev/porting-notes.md`](dev/porting-notes.md)에 있습니다. 복구용 BIN과
readback은 의도적으로 Git에서 제외하며, 외부 백업에 보관할 정확한 파일명과
hash는 [`dev/recovery-files.sha256`](dev/recovery-files.sha256)에 기록합니다.

## 라이선스

이 저장소는 [MIT License](LICENSE)에 따라 배포됩니다. ZMK, keymap-drawer, dfu-util 및 패키지에 포함된 기타 외부 구성 요소에는 각 프로젝트의 라이선스가 적용됩니다.
