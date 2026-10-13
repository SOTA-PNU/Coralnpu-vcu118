# Coralnpu-vcu118

Google [CoralNPU](https://github.com/google-coral/coralnpu) SoC 를 AMD **VCU118**
(xcvu9p-flga2104-2L-e) 에 올리는 저장소.

이 저장소는 상류 코드를 복사해 두지 않는다. **고정된 상류 커밋 + `patches/`** 만 들고 있고,
스크립트가 그 둘을 합쳐서 빌드·다운로드·실행까지 한다.

```
config.sh       상류 커밋, 구성(CONFIG), hw_server 주소, UART 장치 — 버전 고정은 여기만
patches/        상류에 얹는 패치. 번호 순서대로 적용
coral           모든 작업의 입구 (아래)
vivado/         비트스트림 다운로드 Tcl
udev/           USB 권한 규칙
work/ out/ .tools/  (git 제외) 상류 체크아웃 / 산출물 / 내려받은 도구
```

## 보드를 연결한 뒤

```bash
./coral doctor     # 도구·케이블·시리얼 확인
./coral up         # 비트스트림 다운로드 → ROM 배너 확인 → hello.elf 실행 → "CoralNPU is up."
```

`up` 이 하는 일:

1. `out/chip_vcu118_<CONFIG>.bit` 을 Vivado 로 FPGA 에 올린다.
2. USB-UART 에서 부트 ROM 배너를 기다린다:
   `CoralNPU on VCU118: ROM alive, main clock 50 MHz`
3. hw_server 를 내리고 OpenOCD 로 JTAG(BSCANE2) 에 붙어 `out/vcu118_hello.elf` 를
   ITCM/DTCM 에 올리고 실행한다. UART 에 `Hello from CoralNPU ...` … `DONE`.

내 프로그램을 돌릴 때는 `./coral load my_program.elf`, 콘솔만 볼 때는 `./coral console`.

## 처음 한 번

두 PC 구성이다: **빌드 VM**(Vivado, `coral`) 과 **보드 PC**(VCU118 USB 가 꽂힌 서버).

| 스크립트 | 어디서 | 하는 일 |
|---|---|---|
| `tools/create-vcu118-vm.ps1` | Windows (내 PC) | Ubuntu 22.04.5 VM 생성, MAC 고정(라이선스 Host ID), 무인 설치 |
| `tools/vm-setup.sh` | VM 안 | 패키지, Vivado 2026.1 (Virtex UltraScale+ 만), 라이선스 안내, `coral setup` |
| `tools/board-host.ps1` | 보드 PC (Windows) | hw_server 실행 + CP2105 COM 포트 → TCP 5000/5001 중계 |

```powershell
# 내 PC (PowerShell 5.1)
powershell -ExecutionPolicy Bypass -File tools\create-vcu118-vm.ps1
```
```bash
# VM 안
git clone https://github.com/SOTA-PNU/Coralnpu-vcu118.git && cd Coralnpu-vcu118
./tools/vm-setup.sh          # 멈춘 곳의 안내를 따르고 다시 실행
./tools/vm-setup.sh license ~/Downloads/Xilinx.lic
./coral build                # 비트스트림 + hello.elf + 설정 → out/   (Vivado P&R, 1시간+)
```

`CONFIG=vector_highmem ./coral build` 로 ITCM/DTCM 각 1 MB 판을 만든다 (DDR 이 아직 없으므로
큰 프로그램은 이 판).

## 보드 연결

| 커넥터 | 장치 | 용도 |
|---|---|---|
| J106 (micro-B) | Digilent JTAG-SMT2-NC, USB `0403:6014` | 비트스트림, 디버그(OpenOCD) |
| J4 | Silicon Labs CP2105, USB `10c4:ea70` | 콘솔 115200 8N1 (포트 2개 중 배너가 나오는 쪽) |
| J15 | 12V 전원 | **PC ATX 6핀 금지** (핀 배치 다름) |

LED: `0` 클럭 lock · `1` 하트비트 · `2` halted · `3` fault · `7:4` ROM 이 돌리는 패턴.

### 보드가 다른 PC 에 꽂혀 있을 때 (현재 구성)

보드 PC 에서 `tools/board-host.ps1` 을 띄워 두면 VM 은 랜으로만 보드를 다룬다:
비트스트림은 `HW_SERVER=<보드PC>:3121 ./coral program`, 콘솔은 `nc <보드PC> 5000`.
**`load`/`up` 의 원격판(OpenOCD 대신 Vivado JTAG Tcl 로 디버그 포트 접근)은 작업 중**이다 —
OpenOCD 는 USB-JTAG 을 직접 잡아야 해서 네트워크 너머의 보드에는 쓸 수 없다.

## 패치 추가하는 법

```bash
cd work/coralnpu
# ... 수정 ...
git add -A && git commit -m "fpga: 설명"
git format-patch -1 -o ../../patches --start-number <다음 번호>
```

`./coral setup` 은 이미 적용된 패치를 건너뛰므로 몇 번을 다시 돌려도 된다. 상류 커밋을
올리려면 `config.sh` 의 `CORALNPU_COMMIT` 을 바꾸고 `work/` 를 지운 뒤 `setup`.

## 현재 패치

`0001-vcu118-port.patch` — `fpga/` 에 VCU118 탑(`chip_vcu118`), 125 MHz 클럭 생성기,
BSCANE2 디버그 전송, 핀 XDC(AMD 보드 파일과 대조 완료), Vivado 훅(VU9P 는 SLR0~2),
부트 ROM(`rom_park.c`), `hello.c`, OpenOCD 설정 생성기. 자세한 설명은 적용 후
`work/coralnpu/fpga/vcu118/README.md`.

## 알려진 한계

- **DDR4 미연결.** `0x8000_0000` 이상 접근 시 버스가 멈춘다 → CPU_RESET 버튼.
- 아직 실제 Vivado 합성·보드 실행 전. 검증된 것: Verilator lint, 핀 대조, MMCM 계산,
  OpenOCD 설정 파싱, 패치 적용.
- OpenOCD 의 IR 코드는 Vivado 의 BSDL 에서 읽는다(`gen_openocd_cfg.sh`). 첫 실행 때
  `out/openocd_vcu118.cfg` 의 값을 확인해 둘 것.
