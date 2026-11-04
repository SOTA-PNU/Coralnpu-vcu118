# 작업 로그

CoralNPU (상류 `google-coral/coralnpu` @ 15573b69) 를 AMD VCU118 (xcvu9p-flga2104-2L-e) 에 올린 기록.

## [10/7] 환경 준비 — 상류 고정, 포팅 패치, 원클릭 도구

- 상류 fpga/ SoC 를 VCU118 로 옮기는 패치 작성: 125 MHz 클럭, 핀, BSCANE2 디버그 경로, 부팅 ROM (`patches/0001`)
- 저장소 구성: 상류 고정 커밋 + `patches/` + `coral` CLI
  (`setup` / `build` / `program` / `up` / `run` / `resume` / `sw`)

## [10/13] 빌드 환경 — VirtualBox VM + 전용 라이선스

- 공용 서버 사용 불가. Windows PC 에 Ubuntu 22.04 VM 을 만들고, MAC 을 고정해 라이선스 Host ID 로 사용
- VCU118 Device-Locked 라이선스 발급. Vivado 2026.1 설치 후 xcvu9p 합성 확인
- 보드 USB(JTAG, UART)를 VM 으로 패스스루. JTAG tap 0x14b31093 인식

## [10/14] 첫 빌드와 환경 문제

- 빌드 선행 조건 수정
  - clang 미설치
  - Bazel 이 가짜 HOME 을 써서 라이선스를 찾지 못함 → `XILINXD_LICENSE_FILE` 로 전달
- 합성 중 메모리 부족으로 강제 종료 (RAM 20 GB + 스왑 2 GB) → 스왑 추가
- 매트릭스 판(VME) VCU118 타깃 추가, 50 MHz (`patches/0002`)

## [10/16] 첫 보드 bring-up, 상류 버그 발견

- vector_normal 비트스트림
  - LUT 533k (45%)
  - 50 MHz 셋업 충족, WNS +0.26 ns
  - 홀드 위반 6곳은 모두 ISP 의 비동기 리셋 경로
- 배선 도중 VM 이 꺼짐 → 배치 체크포인트에서 배선만 다시 돌려 복구. 이 절차를 `coral resume` 으로 자동화
- 보드 증상: 클럭과 JTAG 은 정상인데 코어가 시작하지 않음
  - LED 7:4 가 움직이지 않음
  - dmstatus 는 running 인데 halt 되지 않음
- **원인 (상류 버그):** `fpga/rtl/coralnpu_soc.sv` 가 `gen_autoboot` 안에서 `rst_main_nqq` 를 선언보다 먼저 사용함
  - 이 참조가 암시적인 미구동 net 이 됨 (Synth 8-3848)
  - Vivado 가 autoboot FSM 을 지움 → CSR resetReg(INIT=1) 를 아무도 풀지 않아 코어가 영원히 리셋 상태
  - netlist 검사(autoboot 셀 0개)와 iverilog 재현으로 확정
  - `patches/0004`: 선언 위치를 위로 옮기고, 합성 직후 autoboot 존재를 확인하는 검사를 추가
- OpenOCD 0.11 호환 (`patches/0003`)
- BSCANE2 경로 실측: IR 18, USER3 0x22924, USER4 0x23924, DR 패딩 문제 없음

## [10/19] CoralNPU 동작 확인

- `./coral up`: ROM 배너 → JTAG 적재 → hello.elf → `DONE`
- RVV 검증 (`vcu118_rvv_test`, `patches/0005`): vadd / vmacc / vredsum / vfmacc 결과가 모두 스칼라와 일치
  - VLEN 128 비트를 하드웨어에서 직접 확인

  | 커널 (N=259, e32) | 벡터 사이클 | 스칼라 사이클 | 배율 |
  |---|---|---|---|
  | vadd.vv u32 m1 | 1,173 | 2,857 | 2.4× |
  | vmacc.vv i32 m4 | 422 | 3,377 | 8.0× |
  | vredsum i32 m8 | 118 | 1,560 | 13.2× |
  | vfmacc.vv f32 m2 | 764 | 5,970 | 7.8× |

- 행렬곱 벤치마크 (`vcu118_matmul_bench`, `patches/0006`, 50 MHz, 결과 일치)

  | 행렬곱 | MAC/cycle | 처리량 | 스칼라 대비 |
  |---|---|---|---|
  | int8×int8→int32, 32×32×32 | 1.50 | 75.5 MMAC/s | 17.1× |
  | f32, 16×16×16 | 0.97 | 48.9 MMAC/s | 17.2× |

- 연속 실행 수정
  - 증상: 프로그램이 끝나면 `mpause` 의 halted 플래그가 남아 다음 프로그램이 실행되지 않음
  - 수정: `coral load` 가 적재 전에 `reset halt` 를 수행
  - 확인: 비트스트림을 다시 올리지 않고 3회 연속 실행
- 콘솔은 CP2105 의 **if01**. ttyUSB 번호는 부팅마다 바뀌므로 by-id 이름으로 찾음

## [확인] 빌드 환경 제약

- 호스트 27 GB 에 VM 20 GB 를 주면 Windows 메모리가 98% 까지 차서 VM 이 멈추거나 꺼짐 → VM 은 16 GB 로 두고 부족분은 VM 안 스왑으로 처리
- Ubuntu 의 systemd-oomd 가 스왑을 쓰는 Vivado 를 강제 종료 → 비활성화 (`tools/setup-host.sh`)
- vector 빌드 소요 시간: 7시간에서 2.5일까지 (메모리 압박에 좌우)
- JTAG 적재 속도는 약 1.5–1.9 KiB/s

## [10/21] matrix_normal 은 VU9P 에 들어가지 않음 (배선 실패)

- 합성 → 배치 → physopt 까지는 완료. 배선(`coral resume`)에서 실패
  - `Route 35-162`: 142,180 개 신호가 혼잡 때문에 배선되지 못함
  - `Route 35-2`: node overlap 330,804 개가 남음
  - overlap 이 1,875,633 에서 시작. vector_normal 은 263,215 에서 시작해 0 까지 내려갔음
- 배치 후 사용률 (`chip_vcu118_physopt.dcp`)

  | 자원 | vector_normal | matrix_normal (ISP 제거) |
  |---|---|---|
  | CLB LUT | 533k (45%) | **1,030k (87%)** |
  | CLB (슬라이스) | — | **99.3%** |
  | 레지스터 | 226k (10%) | 251k (11%) |
  | URAM / DSP | — | 14% / 12% |
  | SLR1→SLR2 교차 | — | 8,854 (51%) |

- 결론
  - 매트릭스 유닛이 LUT 를 약 50만 개 더 씀. VU9P(118만 LUT)에서는 CLB 가 99% 차서 배선 자원이 남지 않음
  - 상류는 매트릭스 판을 VU13P(173만 LUT, 약 60%)에서 쓴다
  - 클럭을 낮춰도 해결되지 않음 (타이밍이 아니라 배선 자원 문제)
  - **VCU118 의 구성은 vector_normal / vector_highmem 으로 확정.** 매트릭스 판은 더 큰 FPGA 가 필요함
- 빌드 환경 메모: 학교 PC 의 VBS / 메모리 무결성 때문에 VirtualBox 가 NEM 모드(AMD-V 미사용)로 동작함
  - 그래서 soft lockup 이 생기고 빌드 시간이 크게 늘어남
  - 보안 설정은 기관 관리 대상이라 원상 복구함

## [10/21] highmem 판으로 진행

- vector_highmem 을 사용함: ITCM / DTCM 각 1 MB, 상류 구성 그대로
- 테스트 프로그램의 highmem 링크판 추가 (`patches/0008`)
  - `*_highmem.elf`
  - matmul 은 int8 128³, f32 64³
- `coral up` / `coral sw` 는 CONFIG 가 *highmem 이면 `_highmem` ELF 를 사용
- `tools/overnight.sh <config>`: 빌드 → 보드 적재 → rvv / matmul

## [10/23] vector_highmem 보드 결과

- 빌드 10/22 16:51 → 10/23 03:41 (약 11시간)
- 타이밍: 라우팅 직후 WNS −0.972 ns → post-route phys_opt 후 **통과** (clk_main 50 MHz WNS 0.000, 실패 0)
- 자원: LUT 43.7%, URAM 192 (20%), BRAM 0, DSP 392
- RVV PASS
- matmul int8 128³ 78.5 MMAC/s (스칼라 대비 17.45배), f32 64³ 52.0 MMAC/s (17.93배)

## [10/26] 모델 ELF 실행 준비: DDR4 + JTAG 로더

- 대상: IREE 모델 ELF (lenet5, charrnn, vgg, yolo)
  - 코드와 가중치가 DDR 0x8000_0000 에 있음 (0.8 ~ 16 MB)
  - 결과는 DTCM 의 `_ret`, `inference_*`, `status_msg`
- 상류(Nexus) 방식
  - DDR4 MIG + `nexus_loader` (FTDI SPI → SoC SPI 디바이스)
  - MIG 코어는 Google 내부 경로에만 있음
- VCU118 에서의 결정 (클럭 50 MHz 유지)
  - DDR4: Vivado IP 카탈로그로 C1 컨트롤러 생성 (보드 파일 사용, AXI 256 비트, ECC 없음)
  - 로더: 보드에 SPI 로 쓸 FTDI 가 없어 JTAG 사용. 디버그 모듈은 TCM 만 접근 가능
    - ITCM 의 작은 스텁(`tools/ddr_stub.S`)이 DDR 로 복사
    - 체크섬으로 검증 후 엔트리로 점프
- 추가한 것
  - `./coral ddr4-probe`: 합성 없이 IP 만 만들어 설정·포트 목록 확인 (몇 분)
  - `./coral model <elf>`: 적재 → 실행 → 결과 출력
- 다음: probe 결과로 `patches/0009` (chip_vcu118 에 DDR4 연결) 작성 → highmem 재빌드

## [10/29] DDR4 C1 연결 (`patches/0009`)

- `./coral ddr4-probe synth` 결과 (Vivado 2026.1, 보드 파일 vcu118 3.0)
  - 인터페이스 `ddr4_sdram_c1_062`, MT40A256M16LY-062E, 64비트, DDR4-2400
  - 보드 프리셋이 폭·속도를 고정함: AXI 512비트, ui_clk 300 MHz (32비트/DDR4-2000 설정은 무시됨)
  - 컨트롤러만 합성: 포트 118개 전부 배치됨 (sys_clk E12, dq[0] F11), LUT 약 2만
- 연결 방식
  - SoC DDR AXI(256비트, 50 MHz) → `axi_dwidth_converter`(256→512, 비동기 클럭 변환) → DDR4 컨트롤러(300 MHz)
  - 상류 Nexus 는 SoC DDR 쪽을 ui_clk 로 돌리지만, 여기서는 300 MHz 를 Xilinx IP 안에만 둠
  - 주소 0x8000_0000 → 컨트롤러 0 (비트 31 제거)
  - DDR 제어 포트(Nexus 의 ECC 레지스터)는 OKAY 응답기
  - 보정 완료 신호 → GPIO 입력 비트 0, LED 7 (LED 6:4 = GPIO 2:0)
- 검사
  - Verilator 로 top 포트 연결 검사 (IP 는 생성된 템플릿으로 만든 stub)
  - 패치 0001~0009 가 상류 15573b6 에 깨끗이 적용되는 것 확인
  - IP 설정이 RTL 과 다르면 setup 훅에서 바로 중단

## [10/29] 보드를 학교 Linux 서버 PC 로 옮기기

- 빌드(라이선스)는 이 PC 의 VM 에 그대로 두고, 서버 PC 는 보드 연결·적재·실행만 맡음
  - ZCU102 는 ARM + 리눅스가 SD 로 스스로 부팅했지만, VCU118 은 USB 로 연결된 호스트가 항상 필요함
- `tools/setup-board-host.sh`: 실행 전용 설치 (openocd, udev, Vivado Lab Edition, 케이블 드라이버, 파일 확인)
- `coral program`: 라이선스가 필요 없는 `vivado_lab` 으로도 동작
- 모델 ELF 는 VM `~/models` 에 복사됨 (Windows → VM: `scp -P 2222`, NAT 포트 전달 127.0.0.1:2222)

## [10/30] 원격 자동화: VM 메일박스 에이전트

- 문제: 연구실 밖에서는 VM 상태를 볼 수 없고, Claude 도 Windows `SOTA` 폴더까지만 닿음
- `tools/vm-agent.sh`: VirtualBox 공유 폴더(`SOTA\vmshare` ↔ VM `/media/sf_coral`)를 통해
  - `status.txt` 를 1분마다 갱신 (빌드 진행 단계, 메모리, 최신 summary)
  - `inbox/*.job` 의 명령을 실행하고 결과를 `outbox/` 에 남김
  - 허용 명령만 실행: status, pull, build, resume, program, model, probe, cancel (나머지는 거부)
- `tools/overnight.sh`
  - 타이밍 요약을 제대로 기록 (constraints met 여부, 클럭별 WNS/WHS, LUT)
  - vector_highmem 이면 빌드·회귀 뒤 `~/models` 의 lenet5 → charrnn → yolo → vgg 를 자동 실행 (첫 실패에서 중단)

## [10/30] DDR4 빌드 결과와 보정 실패 원인

- 빌드 10/29 18:21 → 23:20 (약 5시간)
- 타이밍 통과: clk_main WNS +0.084 ns, DDR4 쪽 +0.039 ns 이상
- LUT 539,187 (45.6%)
- 보드: RVV, matmul 회귀는 이전과 사이클까지 동일하게 PASS
- 문제: `coral model lenet5` 가 "DDR not calibrated" 에서 멈춤. LED 7 꺼짐
  - Vivado 하드웨어 매니저: MIG 디버그 코어는 보이지만 버전 레지스터가 비어 있음
  - 원인: DDR4 컨트롤러 안의 보정용 MicroBlaze BRAM 에 펌웨어(`calibration_ddr.elf`)가 아니라 IP 의 빈 부트 루프가 들어가 있었음
  - 상류 Nexus 의 `vivado_hook_write_bitstream_post.tcl` 이 바로 이 단계 (그쪽 코어 전용으로 보고 빠뜨렸던 것)
- `write_mem_info` 는 두 번째 BRAM 뱅크(32 KB)를 빠뜨려 updatemem 실패 → BMM 정보로 MMI 를 직접 만듦
- `patches/0010`: 비트스트림 쓰기 전/후 훅으로 매 빌드 자동 삽입
- `./coral ddr4-fw`: 이미 만든 비트스트림에 펌웨어만 넣기 (재빌드 없음, 약 15분)

## [10/30 오후] 펌웨어를 넣어도 보정 안 됨 → 진단 빌드

- `coral ddr4-fw` 성공 (MMI: 64 KB + 32 KB 뱅크, 0..98303), 보드 적재 후에도 LED 7 꺼짐, CPU_RESET 후에도 동일
- Vivado MIG 상태 레지스터는 여전히 비어 있음. 단, 우리 설계는 MIG 디버그 클럭(dbg_clk)을 디버그 허브에 연결하지 않아 이 값은 믿을 수 없음
- LED 0 켜짐, LED 1 깜빡임, 부트 ROM 정상 → 코어 쪽 정상, 문제는 DDR4 컨트롤러 안쪽
- `patches/0011` 진단 빌드: LED 5 = ui_clk 동작, LED 6 = 컨트롤러 리셋 해제, LED 7 = 보정 완료; GPIO 입력 비트 1 = 리셋 해제; 디버그 허브를 dbg_clk 로 연결(MIG 예제 설계 방식)해 보정 단계 확인 가능
- `coral program` 이 cs_server 도 종료 (남은 cs_server 가 CPU 100% 를 계속 쓰던 문제)
- VM 보안 점검: SSH 로그인은 모두 10.0.2.2(호스트 PC), crontab·authorized_keys 없음. 채굴 침해는 다른 Linux 기기(actions-runner) 쪽으로 보임

## [10/31] 0011 진단 판 결과: 컨트롤러가 리셋에서 안 나옴

- 빌드 약 7시간 47분, 타이밍 통과. RVV, matmul 은 그대로 PASS
- lenet5: 보정 시간 초과. GPIO 입력 = 0x0 → 비트 1(리셋 해제) = 0, 컨트롤러가 리셋 상태로 멈춰 있음
- 로더 보강 (재빌드 없음)
  - 디버그 모듈은 TCM 만 접근 가능해 호스트에서 GPIO(0x4003_0000)를 직접 못 읽음
  - 스텁이 GPIO 값을 메일박스 +24 에 기록 → 호스트가 시간 초과 시 비트별로 출력
- 리셋 극성 확인 (`coral ddr4-probe`)
  - IP 에는 극성 CONFIG 가 없고 `.xci` 인터페이스 메타데이터에만 있음: `SYSTEM_RESET` = ACTIVE_HIGH → RTL 과 일치
  - 핀 확인(synth 모드, 이제 기본): 118 포트 전부 배치, `c0_sys_clk_p → E12 DIFF_SSTL12`
- 실수: 진단 로그를 넣으려고 이미 적용된 `patches/0009` 를 고침 → `coral` 이 "changed since it was applied" 로 모든 빌드 중단. 11/02 되돌림
  - 규칙: 적용된 패치 파일은 고치지 않는다. 빌드 변경은 새 번호 패치로, probe 용은 루트의 `vivado/*.tcl` 로

## [11/02] 0012 판: 파워온 리셋 카운터 — 여전히 리셋 상태

- `patches/0012`: 컨트롤러 sys_rst 를 STARTUPE3 EOS 대신 메인 클럭 카운터로 구동. GPIO 비트 2 = EOS, 비트 3 = 파워온 리셋
- 빌드 08:56 → 18:08 (**9시간 10분**), clk_main WNS +0.170, LUT 539,385 (45.62%)
- RVV, matmul PASS (int8 128³ 17.45x, f32 64³ 17.93x)
- lenet5: GPIO 입력 = 0x0 (calibrated / out-of-reset / eos / por-held 전부 0)
  - 파워온 리셋은 해제됐는데 컨트롤러는 리셋 → 250 MHz 기준 클럭 쪽이 남은 용의자
  - 단, 0011·0012 두 판에서 이 GPIO 워드의 비트가 1 로 읽힌 적이 한 번도 없음 → "GPIO 읽기 경로 고장" 하나로도 설명 가능. 다음 RTL 변경 때 상수 1 비트를 넣어 자가 검증할 것
- probe 에 클럭 덤프 추가: 생성된 IP 의 MMCM 이 `CLKIN1_PERIOD 14.161`, `CLKFBOUT_MULT_F 17`, xdc `create_clock -period 14.161`
  - 보드 250 MHz 를 넣으면 VCO = 4250 MHz → MMCME4 상한(약 1600 MHz) 초과 → 락 실패 → ui_clk 없음 → 보정 시작 안 됨

## [11/03] DDR4 원인 확정과 수정 (`patches/0013`)

- 원인: `vcu118_ddr4_c1_ip.tcl` 의 `CONFIG.C0.DDR4_TimePeriod 1000` 요청
  - 보드 프리셋이 C1 을 DDR4-2400(833 ps)으로 고정해 이 요청을 거부함. 무해한 no-op 으로 봤지만 아니었음
  - 요청 시 IP 가 입력 클럭 주기를 1000 ps 기준으로 다시 계산 → TimePeriod 만 833 으로 돌아가고 입력 주기는 17 × 833 = 14161 ps(70.6 MHz)로 남음
- IP 네 개를 한 단계씩 바꿔 비교 (InputClockPeriod)
  - a 현행 14161 / b 요청 삭제 **4000** / c 현행 + 4000 강제 14161 / d 삭제 + 4000 강제 **4000**
  - → 삭제만으로 충분. 4000/833 = 4.8 이라 강제로는 못 고침
- 잃는 것 없음: 1000 ps 는 어떤 빌드에서도 적용된 적 없음. SoC 쪽 CDC 는 `ddr4_c1_axi_up` 비동기 FIFO 가 처리
- `patches/0013` + `vivado/ddr4_c1_ip.tcl` 같은 수정
- 빌드 전 검증 probe 통과
  - `InputClockPeriod 4000`, xdc `create_clock -period 4.0`
  - MMCM `CLKIN1_PERIOD 4.000`, `CLKFBOUT_MULT_F 6`, `CLKOUT0_DIVIDE_F 5` → VCO 1500 MHz, ui_clk 300 MHz (3.333 ns), PHY PLL ×4 = 1200 MHz (tCK 833 ps)
- 17:35 vector_highmem 빌드 시작 (0013 적용, 끝나면 모델 4개 자동 실행)
- 미측정: E12 에 250 MHz 가 실제로 들어오는지 (빌드 결과의 LED 5 / GPIO 비트 1 로 확인)

## [11/04] DDR4 동작, 모델 4개 보드 실행 — 진짜 원인은 로더

- 0013 판 빌드 17:35 → 06:57 (**13시간 22분**: VM 메모리 13/15 GB + swap, 그동안 VM 에이전트도 멈춤). clk_main WNS +0.229, LUT 45.60%
- RVV, matmul PASS. lenet5 는 또 GPIO = 0x0, 이번엔 eos=0 까지 → 설정이 끝난 FPGA 에서 EOS 는 항상 1 이므로 이 0 은 GPIO 값이 아님
- 확인: 메일박스 GPIO 칸을 `0xA5A5A5A5` 로 채우고 실행 → 그대로 남음, 스텁 pc 는 0x8 → 0xc → 0xc
- **원인:** 상류 `Lsu.scala` 는 코어의 ITCM store 를 access fault 로 처리(`ibusFault = write && itcm`). 스텁 메일박스가 ITCM 0x100 이라 첫 `sw` 에서 fault → 0 번지로 돌아가 무한 반복
  - **0011·0012·0013 의 "GPIO = 0x0" 은 측정이 아니라 로더가 써 둔 초기값이었다.** 그 판들의 실제 DDR4 상태는 알 수 없음
  - "읽는 쪽이 살아 있다는 증거"를 계측에 넣지 않은 탓. 앞으로 센티널 필수
- 수정: 메일박스를 DTCM `0x1F_F000` 으로 (`li s0` 한 워드만 바뀜) → **`DDR calibrated` 0.4 s**
- 0013 이 실제로 필요했는지는 미확정 (0013 없는 판을 같은 로더로 돌려 보지 않음). 0013 없이 만든 IP 의 VCO 4250 MHz 계산은 그대로 유효
- JTAG 적재 실측 1.29 KB/s (워드마다 abstract command + USB 왕복) → yolo 2.7 h, vgg 3.4 h
- **UART 로더** (재빌드 없음): UART1 RX 는 0001 부터 CP2105 에 연결돼 있었음. 스텁 cmd 5 = UART1 에서 n 바이트를 DDR 로. 호스트는 termios 921600 8N1
  - 실측 **73.8 KB/s (JTAG 의 57 배)**, 체크섬·출력값 JTAG 와 동일
- 결과 ([MODEL_ELF.md](MODEL_ELF.md) 에 실행 조건과 함께 정리)

| 모델 | UART 적재 | 실행 | argmax | `_ret` |
|---|---|---|---|---|
| lenet5 (821 KB) | 11.2 s | 2 s (560.6 ms) | 7 | 0 |
| charrnn (2062 KB) | 27.9 s | 4 s (3173.6 ms) | 53 | 0 |
| yolo (12333 KB) | 166.9 s | 736 s | 959 | 0 |
| vgg (15868 KB) | 215.6 s | 94 s (82.5 s) | 92 | 0 |

- 정답 여부는 미판정 (기준값 없음). `cyc_*` 는 32비트라 86 초마다 넘침 — 긴 실행은 벽시계 기준
- OpenOCD 0.11 이 생성 설정의 `riscv set_mem_access abstract` 를 모름 (오류 출력, 동작엔 무관)

## [11/04 오후] 보드가 직접 UART 로 결과 출력, 보드를 연구실 서버로

- 보드 직접 출력 (`tools/result_printer.S`, 모델 ELF 재빌드 없음)
  - 4개 모델 crt0 끝이 같음: `sw a0,_ret ; beqz ; ebreak ; … ; mpause ; j .` → 로더가 DDR 이미지에서 beqz/ebreak 두 워드를 `lui t0,0 ; jalr x0,0x400(t0)` 로 바꿔 ITCM 0x400 출력 루틴으로 보냄
  - 출력 루틴: ITCM 0x800 표(호스트가 만듦)를 따라 결과 심볼을 hex 로 찍고 줄 끝에 `=합`, 끝나면 완료 플래그 + mpause
  - 호스트: tty 수신 스레드, 줄 합 검증, 디버거로 읽은 값과 대조
  - 어셈블러가 없는 호스트라 `tools/rvasm.pl` (RV32I 소형 어셈블러). `--check` 로 스텁 69 + 출력 루틴 96 워드가 소스와 일치함을 확인
- VM(VirtualBox USB 패스스루)에서 yolo 출력 텐서(862 KB → 텍스트 2 MB)가 2.8 % 유실 → 흐름 제어(256 바이트마다 ACK)와 줄 체크섬 추가. 첫 ACK 계산은 유실 후 한 블록씩 밀려 0.2 s/블록으로 멈춤 → 블록 경계 재동기화로 수정
- 보드를 연구실 서버 sota-AIP (192.168.1.150, Ubuntu 24.04, 24코어, 62 GB) 로 이전
  - Vivado Lab 2026.1 (SFD), OpenOCD 0.12, 케이블 드라이버, en_US.UTF-8 로캘. 설치 스크립트 수정 3건(d303246)
  - 이 PC 의 VM 은 빌드 전용으로 남음 (새 PC 로 이전 예정)
- 서버 실측 (UART 921600, 흐름 제어)

| 항목 | 결과 |
|---|---|
| lenet5 / charrnn / vgg | argmax 7 / 53 / 92, 줄 합 17/17, 디버거 대조 17/17. 15.7 s / 34.4 s / 309.8 s |
| yolo | argmax 959, **출력 텐서 215,475 워드 전부, 깨진 토큰 0, 재동기화 0**, 출력 23 s, 전체 918.6 s |
| RVV / matmul | PASS, 사이클 이전과 동일 (int8 128³ 17.45x, f32 64³ 17.93x) |

- 유실 원인은 VirtualBox USB 경로로 추정 (서버 직결에서는 0). 측정으로 분리하지는 않음
- CI: `.github/workflows/board-test.yml` (self-hosted `vcu118` 러너, 서버 `~/actions-runner-vcu118`)

## [진행 예정]

- (보류) 매트릭스 판: VU13P 급 보드에서. `vcu118_vme_test` 는 준비돼 있음
- 빌드 전용 PC 확보 (메모리 64 GB 이상, VBS 없음)
- (급하지 않음) 보드를 학교 Linux 서버 PC 로 이전: `tools/setup-board-host.sh` → 보드 USB·전원 이동 → VM 에서 .bit / openocd cfg / ~/models 복사 → `coral program`, `coral model`
- 보드에 올린 ELF 에 벡터 명령이 실제로 들어 있는지 objdump 로 확인
- 행렬곱 커널 최적화 (레지스터 블로킹), 신경망 레이어 단위 측정
- 모델 출력 정답 판정: 입력 라벨 또는 호스트 실행 결과 확보
- 보드를 AIP 공용 Linux 서버로 이전 (`tools/setup-board-host.sh`), 이후 보드 CI (self-hosted 러너)
- 빌드 전용 PC: 0013 판이 메모리 부족으로 13 시간
- 힙 실사용량, 64비트 사이클 카운터(mcycleh)로 긴 실행 측정
- `overnight.sh` 가 빌드 단계(synth/P&R/비트스트림)를 summary 에 기록
- 상류 결함 보고: autoboot 리셋 net 선언 순서 (Nexus ROM 빌드도 같은 문제로 추정)
