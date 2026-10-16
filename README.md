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

빌드 중 VM 이 꺼지면 **다른 bazel/coral build 를 돌리기 전에** `./coral resume` — Bazel 샌드박스에
남은 Vivado 체크포인트(opt/placed/physopt/routed)에서 이어서 비트스트림을 만든다. 이어서 `./coral sw`
(hello.elf + OpenOCD 설정), `./coral up`.

내 프로그램을 돌릴 때는 `./coral load my_program.elf`, 콘솔만 볼 때는 `./coral console`.

## 처음 한 번

**현재 구성 (2026-10-13): 빌드는 VM, 실행은 fractal.**
Vivado 라이선스는 공용 서버에 묶지 않고 VM(MAC 고정)에 발급한다. 비트스트림 다운로드·디버그·콘솔은
라이선스가 필요 없으므로 보드 USB 가 꽂힌 fractal 에서 한다.

```
[VM vcu118-dev]  ./coral build  →  out/*.bit, out/vcu118_hello.elf
      │  ./coral deploy up   (scp + ssh, sota.pusan.ac.kr:10022)
      ▼
[fractal]        ./coral up  (hw_server, OpenOCD, UART — 로컬 USB)
```

```bash
# 양쪽 공통 (VM 과 fractal 각각)
git clone https://github.com/SOTA-PNU/Coralnpu-vcu118.git && cd Coralnpu-vcu118
./tools/setup-host.sh        # 멈춘 곳의 안내를 따르고 다시 실행
# VM 에서만
./tools/setup-host.sh license ~/Downloads/Xilinx.lic
./coral build
./coral deploy up            # fractal 로 복사하고 거기서 coral up 실행
```

`setup-host.sh` 가 하는 일: 패키지(openocd, picocom 포함), libtinfo.so.5 (24.04 는 .so.6 로 링크),
VCU118 USB udev 규칙, Vivado 2026.1 설치(ML Enterprise, Virtex UltraScale+ 만),
Digilent 케이블 드라이버, 라이선스 안내(이 호스트의 MAC), `coral setup`.
서버에 모니터가 없으면 Vivado 설치 파일은 내 PC 브라우저에서 받아 `scp` 로 `~/Downloads` 에 넣는다.

공용 서버이므로 `coral` 은 **내 hw_server 만** 종료한다. 다른 사용자의 hw_server 가 JTAG 을
잡고 있으면 멈추고 알려 준다.

`CONFIG=<구성> ./coral build` 로 다른 판을 만든다. 모두 50 MHz.

| CONFIG | 유닛 | ITCM / DTCM |
|---|---|---|
| `vector_normal` (기본) | 스칼라 + RVV | 8 KB / 32 KB |
| `vector_highmem` | 스칼라 + RVV | 1 MB / 1 MB |
| `matrix_normal` | 스칼라 + RVV + 매트릭스(VME/ZVT) | 8 KB / 32 KB |
| `matrix_highmem` | 스칼라 + RVV + 매트릭스(VME/ZVT) | 1 MB / 1 MB |

상류 Nexus 는 매트릭스 판을 30 MHz 로 돌린다. VCU118 은 50 MHz 로 시도하므로
`out/reports_<CONFIG>/` 의 타이밍 리포트에서 WNS ≥ 0 인지 먼저 확인할 것.
DDR 이 아직 없으므로 큰 프로그램은 highmem 판.

합성에 RAM+스왑 약 40 GB 가 필요하다 (20 GB + 2 GB 에서 OOM 으로 죽음).

### 다른 구성 (보조)

| 스크립트 | 언제 |
|---|---|
| `tools/create-vcu118-vm.ps1` | 리눅스 서버가 없을 때 Windows 에 Ubuntu 22.04 VM 을 만든다 (MAC 고정) |
| `tools/board-host.ps1` | 보드가 Windows PC 에 꽂혀 있을 때: hw_server + COM→TCP 중계 |

## 보드 연결

| 커넥터 | 장치 | 용도 |
|---|---|---|
| J106 (micro-B) | Digilent JTAG-SMT2-NC, USB `0403:6014` | 비트스트림, 디버그(OpenOCD) |
| J4 | Silicon Labs CP2105, USB `10c4:ea70` | 콘솔 115200 8N1 (포트 2개 중 배너가 나오는 쪽) |
| J15 | 12V 전원 | **PC ATX 6핀 금지** (핀 배치 다름) |

LED: `0` 클럭 lock · `1` 하트비트 · `2` halted · `3` fault · `7:4` ROM 이 돌리는 패턴.

### 보드가 다른 PC 에 꽂혀 있을 때

빌드 머신과 보드 PC 가 다르면 비트스트림은 `HW_SERVER=<보드PC>:3121 ./coral program` 으로
올릴 수 있지만, `load`/`up` 은 OpenOCD 가 USB-JTAG 을 직접 잡아야 하므로 보드가 꽂힌 머신에서
실행해야 한다.

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

`0002-vcu118-matrix-50mhz.patch` — 매트릭스 판 VCU118 타깃, ZVT 플래그 전달, 전 구성 50 MHz.

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
