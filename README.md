# Coralnpu-vcu118

Google [CoralNPU](https://github.com/google-coral/coralnpu)(RISC-V 스칼라 + RVV 벡터 NPU)를
AMD **VCU118**(xcvu9p-flga2104-2L-e)에 올리고, IREE로 컴파일한 신경망 모델을 보드에서 실행하는 저장소.

**상태 (2026-11-04, 마무리):** IREE 모델 4종(lenet5, charrnn, yolo, vgg)이 보드에서 끝까지 추론된다.
보드는 연구실 서버 sota-AIP에 있고, GitHub Actions `board-test`가 매주 검증한다.

| 문서 | 내용 |
|---|---|
| [docs/SUMMARY.md](docs/SUMMARY.md) | **프로젝트 정리**: 결과, 리소스, 동작 방식, 한계, 운영, 올리는 법 |
| [docs/BENCHMARK.md](docs/BENCHMARK.md) | 반복 측정, MAC 효율, 다른 구현과 비교 |
| [docs/MODEL_ELF.md](docs/MODEL_ELF.md) | 어떤 모델 ELF가 돌아가는지 (명령어 셋, 메모리 배치, 결과 심볼) |
| [docs/LOG.md](docs/LOG.md) | 날짜별 진행 기록과 측정값 |

## 한눈에

| 항목 | 값 (보드 실측) |
|---|---|
| 구성 | `vector_highmem`: 스칼라 RV32IMF + RVV(VLEN 128), ITCM 1 MB, DTCM 1 MB, DDR4 |
| 클럭 / 리소스 | 50 MHz, WNS +0.229 ns, LUT 45.6 % |
| 행렬 곱 | int8 128³ **1.57 MAC/cycle**, 스칼라 대비 17.45× · f32 64³ 1.04 MAC/cycle, 17.93× |
| 모델 추론 | lenet5 560.7 ms · charrnn 3.15 s · vgg 81.5 s · yolo 약 736 s |
| 모델 적재 | USB-UART 73.8 KB/s (JTAG의 57배) |
| 검증 | DDR 체크섬, 보드 UART 출력 줄 체크섬, 디버거 대조, argmax 회귀 |

## 저장소 구조

이 저장소는 상류 코드를 복사해 두지 않는다. **고정된 상류 커밋 + `patches/`**만 들고 있고,
`coral`이 둘을 합쳐 빌드·적재·실행까지 한다.

```
config.sh       상류 커밋, 구성(CONFIG), hw_server 주소, UART 장치 — 버전 고정은 여기만
patches/        상류에 얹는 패치 0001~0013. 번호 순서대로 적용, 적용된 것은 고치지 않는다
coral           모든 작업의 입구
tools/          모델 로더(ddr_run.py), 보드 도우미(ddr_stub.S, result_printer.S, rvasm.pl),
                서버·VM 설치 스크립트, 야간 빌드, VM 메일박스 에이전트
vivado/         비트스트림 다운로드, DDR4 IP 생성·검사 Tcl
udev/           보드 USB 권한 규칙
.github/        보드 CI (board-test)
work/ out/ .tools/  (git 제외) 상류 체크아웃 / 산출물 / 내려받은 도구
```

## 지금의 구성

```
[빌드 VM, Vivado 라이선스]  ./coral build  →  out/chip_vcu118_vector_highmem.bit, 테스트 ELF
          │ scp (비트스트림·설정·ELF, SHA256SUMS)
          ▼
[sota-AIP, 보드 USB]        ./coral program  (Vivado Lab, 무료)
                            ./coral model ~/models/<elf>   (OpenOCD + USB-UART)
                            GitHub Actions board-test (self-hosted 러너 'vcu118')
```

- 빌드는 Vivado 라이선스가 VM(MAC 고정)에 묶여 있어 VM에서만 한다. 한 판에 9~13시간.
- 보드 쪽은 라이선스가 필요 없다 (Vivado Lab 2026.1, OpenOCD 0.12).

## 보드에서 실행 (sota-AIP)

```bash
cd ~/Coralnpu-vcu118
CONFIG=vector_highmem ./coral program              # 비트스트림 (전원을 껐다 켠 뒤 한 번)
./coral run out/vcu118_rvv_test_highmem.elf        # RVV 회귀 → "RVV PASS"
./coral run out/vcu118_matmul_bench_highmem.elf    # 행렬 곱 → "MATMUL PASS"
./coral model ~/models/lenet5                      # IREE 모델
./coral model ~/models/yolo --timeout 2400         # 15분 넘게 도는 모델
```

`coral model`이 하는 일 (자세히는 [SUMMARY.md §4](docs/SUMMARY.md)):

1. JTAG로 ITCM에 적재 스텁(0x0)과 결과 출력 루틴(0x400)을 올린다.
2. 스텁이 DDR4 보정 완료를 확인한다.
3. DDR 세그먼트를 USB-UART(921600)로 보내고 체크섬을 맞춘다.
4. 모델을 실행한다. 끝나면 보드가 결과를 UART로 직접 출력한다 (줄마다 체크섬).
5. 호스트가 줄 체크섬을 검증하고, 디버거로 읽은 값과 대조한다.
   결과 텍스트는 `out/results/<모델>-<시각>.uart.txt`.

옵션: `--jtag` (UART 없이, 57배 느림), `--no-print` (보드 직접 출력 끄기).

## CI

GitHub → Actions → **board-test** → Run workflow (모델 선택, 기본 lenet5 charrnn vgg).
매주 월 04:00 KST에 4종 전부 자동 실행. program → RVV → matmul → 모델 순서이고,
모델마다 `_ret = 0`, 줄 체크섬, 디버거 대조, argmax(7/53/959/92)를 확인한다.
PR로는 실행되지 않는다 (포크 코드가 연구실 서버에서 돌지 않게).

## 처음 한 번

### 보드 서버 (라이선스 불필요)
```bash
git clone https://github.com/SOTA-PNU/Coralnpu-vcu118.git && cd Coralnpu-vcu118
./tools/setup-board-host.sh      # 멈춘 곳의 안내를 따르고 다시 실행
```
패키지(openocd, picocom), udev 규칙, Vivado Lab 2026.1(설치 파일을 `~/Downloads`에),
Digilent 케이블 드라이버, `en_US.UTF-8` 로캘을 확인·설치한다. sudo가 필요하다.
그 다음 빌드 VM에서 비트스트림·`openocd_vcu118.cfg`·테스트 ELF를 `out/`에, 모델 ELF를 `~/models/`에 복사한다.

### 빌드 머신 (라이선스 필요)
```bash
./tools/setup-host.sh                             # 패키지, Vivado 2026.1(Virtex UltraScale+), 드라이버
./tools/setup-host.sh license ~/Downloads/Xilinx.lic
CONFIG=vector_highmem ./coral build
```
합성에 RAM+swap 약 40 GB가 필요하다. 빌드 중 VM이 꺼지면 다른 빌드를 돌리기 전에
`./coral resume`으로 Vivado 체크포인트에서 이어 간다.
Windows에 VM을 만들 때는 `tools/create-vcu118-vm.ps1` (MAC 고정).

### 구성

`CONFIG=<구성> ./coral build`. 모두 50 MHz.

| CONFIG | 유닛 | ITCM / DTCM | 상태 |
|---|---|---|---|
| `vector_normal` (기본) | 스칼라 + RVV | 8 KB / 32 KB | 보드 확인 (DDR 없음) |
| `vector_highmem` | 스칼라 + RVV | 1 MB / 1 MB | **사용 중** (DDR4 포함) |
| `matrix_normal` | + 매트릭스(VME/ZVT) | 8 KB / 32 KB | VU9P에 안 들어감 |
| `matrix_highmem` | + 매트릭스(VME/ZVT) | 1 MB / 1 MB | VU9P에 안 들어감 |

## 보드 연결

| 커넥터 | 장치 | 용도 |
|---|---|---|
| J106 (micro-B) | Digilent JTAG-SMT2-NC, USB `0403:6014` | 비트스트림, 디버그(OpenOCD) |
| J4 | Silicon Labs CP2105, USB `10c4:ea70` | UART1: 콘솔 115200, 모델 적재·결과 921600. FPGA 쪽은 `if01` |
| J15 | 12V 전원 | **PC ATX 6핀 금지** (핀 배치 다름) |

LAN은 쓰지 않는다 (베어메탈, 호스트가 USB로 모든 일을 한다).
LED: `0` 클럭 lock · `1` 하트비트 · `2` halted · `3` fault · `5` DDR4 ui_clk · `6` DDR4 리셋 해제 · `7` DDR4 보정 완료.

## 바꾸고 올리는 법

자세히는 [SUMMARY.md §7](docs/SUMMARY.md). 핵심만:

- **이미 적용된 `patches/*.patch`는 고치지 않는다.** `coral`이 "changed since it was applied"로
  모든 빌드를 멈춘다. RTL·빌드 변경은 새 번호 패치로:
  ```bash
  ./coral setup && cd work/coralnpu
  # ... 수정 ...
  git add -A && git commit -m "fpga/vcu118: 설명"
  git format-patch -1 -o ../../patches --start-number 14
  ```
- `tools/`, `vivado/`, `coral`, 문서는 바로 고쳐 커밋한다.
- `tools/ddr_stub.S`·`tools/result_printer.S`를 고치면 `perl tools/rvasm.pl`로 다시 어셈블해
  `ddr_run.py`의 워드를 바꾸고 `perl tools/rvasm.pl --check`로 확인한다.
- `git push origin main` 후 서버는 `git pull --ff-only`, 그리고 Actions에서 board-test.

## 패치

| 번호 | 내용 |
|---|---|
| 0001 | VCU118 탑(`chip_vcu118`), 클럭, BSCANE2 디버그, 핀 XDC, 부트 ROM, hello, OpenOCD 설정 생성기 |
| 0002 | 매트릭스(VME/ZVT) 판 타깃, 전 구성 50 MHz |
| 0003 | OpenOCD 0.11 호환 (`set_mem_access` 없음) |
| 0004 | autoboot 리셋 net 선언 순서 (상류 결함) |
| 0005 | RVV 스모크 테스트 (vadd, vmacc, vredsum, vfmacc) |
| 0006 | ISP 제거, int8/f32 행렬 곱 벤치마크 |
| 0007 | 매트릭스 유닛 스모크 테스트 |
| 0008 | 테스트 프로그램 highmem 판, int8 128³ |
| 0009 | DDR4 C1 연결 (0x8000_0000, AXI 256→512, 비동기 클럭 변환) |
| 0010 | DDR4 보정 펌웨어를 비트스트림에 삽입 |
| 0011 | DDR4 bring-up 가시성 (LED, GPIO, MIG 디버그 허브) |
| 0012 | DDR4 파워온 리셋 카운터 |
| 0013 | DDR4 입력 클럭: `TimePeriod 1000` 요청 삭제 (VCO 4250 → 1500 MHz) |

## 알려진 한계

- 모델 출력의 정답 판정은 아직 없다 (argmax는 회귀 기준).
- 매트릭스 판은 VU9P에 들어가지 않는다 (LUT 87 %, CLB 99 %). VU13P급 필요.
- IREE 모델은 하드웨어 여력(1.57 MAC/cycle)의 5 % 이하만 쓴다 — 병목은 IREE 코드 생성·런타임 ([BENCHMARK.md](docs/BENCHMARK.md)).
- `cyc_*` 카운터는 32비트라 86초가 넘는 실행은 넘친다.
- 압축 명령어(C)·double(D) 없음. 모델 ELF는 ITCM 세그먼트가 없어야 한다 ([MODEL_ELF.md](docs/MODEL_ELF.md)).
- 빌드는 라이선스 VM에서만, 9~13시간. CI에는 빌드가 없다.
- 전체 목록은 [SUMMARY.md §5](docs/SUMMARY.md).
