#!/bin/sh
set -eu

program_path=${PROGRAM_PATH:-./mfclo64}

if [ ! -x "$program_path" ]; then
  echo "MFCL executable not found: $program_path" >&2
  echo "Place mfclo64 beside doitall.sh or set PROGRAM_PATH=/path/to/mfclo64." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Deterministic seed-23 base initialization
# ---------------------------------------------------------------------------
# This is the exact CV=0.1 active-parameter perturbation path used by the
# selected best-objective converged seed-23 fit. Parameters already represented
# after Phase 1 are initialized there. The eight DM CEST parameters represented in
# Phase 2 and the 25 regional-index selectivity coefficients first represented
# after the Phase-5 group split are initialized immediately before their first
# optimization. A parameter is initialized once, never once per phase.
#
# mfclkit's ordinary phase1/doitall jitter runner stages
# mfk_phase1_baseline.par before resuming the script. In that context this base
# bootstrap is deliberately skipped: downstream jitter therefore remains the
# existing makepar-based seed ensemble and does not add seed 23 a second time.
seed23_audit_dir=seed23-initialization
seed23_initialization=${SEED23_INITIALIZATION:-1}
case "$seed23_initialization" in
  1|true|TRUE|yes|YES)
    seed23_apply=true
    ;;
  0|false|FALSE|no|NO)
    seed23_apply=false
    echo "Standard makepar initialization selected: seed-23 checkpoints will not be applied."
    ;;
  *)
    echo "SEED23_INITIALIZATION must be 1/true/yes or 0/false/no." >&2
    exit 1
    ;;
esac
if [ -s mfk_phase1_baseline.par ] || [ -s mfk_fitted_baseline.par ]; then
  seed23_apply=false
  echo "Existing jitter resume detected: seed-23 base initialization will not be applied again."
fi

# The exact Phase 1, 2 and 5 seed-23 checkpoints are archived here. Reusing
# those byte-verified checkpoints removes the private mfclkit runtime dependency
# while retaining the fitted path.
seed23_initialize()
{
  mode=$1
  input_par=$2
  probe_par=$3
  output_par=$4
  phase=$7
  checkpoint_root=${SEED23_CHECKPOINT_DIR:-checkpoints}

  case "$phase" in
    1)
      phase_tag=phase01
      expected_input=d6e0464187da0af8142e21070eff0a41
      expected_probe=
      expected_output=e486df1671237dfd9908cfb7b5da3814
      ;;
    2)
      phase_tag=phase02
      expected_input=42fbc2f4b19d127df30ffdeaecbc007e
      expected_probe=acf11f080de93b971f50d3e886cb5c92
      expected_output=cfb370969b5e50da337eeca3f26a5385
      ;;
    5)
      phase_tag=phase05
      expected_input=5c77e7d1dcccf6333e51d0b61772ff2a
      expected_probe=85e9c638132ed2a4e3671e91a6d5003d
      expected_output=2ae0b5d28fb0b96ac91a83424d0ba900
      ;;
    *)
      echo "Unsupported seed-23 checkpoint phase: $phase" >&2
      exit 46
      ;;
  esac

  checkpoint=$checkpoint_root/$phase_tag-seed23.par
  summary=$checkpoint_root/$phase_tag-summary.csv
  mapping=$checkpoint_root/$phase_tag-mapping.csv
  for required in "$checkpoint" "$summary" "$mapping"; do
    if [ ! -s "$required" ]; then
      echo "Missing archived seed-23 checkpoint file: $required" >&2
      exit 46
    fi
  done

  observed_input=$(md5sum "$input_par" | awk '{print $1}')
  if [ "$observed_input" != "$expected_input" ]; then
    echo "Warning: seed-23 $phase_tag pre-checkpoint hash differs across runtimes." >&2
    echo "Expected $expected_input; observed $observed_input; applying the verified checkpoint." >&2
  fi
  if [ -n "$expected_probe" ]; then
    observed_probe=$(md5sum "$probe_par" | awk '{print $1}')
    if [ "$observed_probe" != "$expected_probe" ]; then
      echo "Warning: seed-23 $phase_tag probe hash differs across runtimes." >&2
      echo "Expected $expected_probe; observed $observed_probe; applying the verified checkpoint." >&2
    fi
  fi
  observed_output=$(md5sum "$checkpoint" | awk '{print $1}')
  if [ "$observed_output" != "$expected_output" ]; then
    echo "Seed-23 $phase_tag checkpoint hash mismatch." >&2
    echo "Expected $expected_output; observed $observed_output." >&2
    exit 46
  fi

  cp "$checkpoint" "$output_par"
  cp "$summary" "$seed23_audit_dir/$phase_tag-summary.csv"
  cp "$mapping" "$seed23_audit_dir/$phase_tag-mapping.csv"
  echo "Seed-23 initialization: $phase_tag checkpoint verified and applied."
}

phase10_11_convergence=${BET_PHASE10_11_CONVERGENCE:--4}
case "$phase10_11_convergence" in
  -[0-9]|-[0-9][0-9]|[0-9]|[0-9][0-9]) ;;
  *)
    echo "BET_PHASE10_11_CONVERGENCE must be numeric, e.g. -3 for quick runs or -5 for strict runs." >&2
    exit 1
    ;;
esac
echo "PHASE 10/11 convergence criterion: $phase10_11_convergence"

regional_recruitment_penalty=${REGIONAL_RECRUITMENT_PENALTY:-0.1}
case "$regional_recruitment_penalty" in
  0.1)
    regional_recruitment_penalty_flag=0
    ;;
  0.2)
    # MFCL stores ten times this coefficient in age flag 110.
    regional_recruitment_penalty_flag=2
    ;;
  *)
    echo "REGIONAL_RECRUITMENT_PENALTY must be 0.1 or 0.2." >&2
    exit 39
    ;;
esac
echo "Regional recruitment-distribution penalty: $regional_recruitment_penalty (age flag 110=$regional_recruitment_penalty_flag)"

dm_nmax=25
dm_concentration=7
echo "DM controls: Nmax=$dm_nmax; grouped fish_pars(22) fixed at $dm_concentration; fish_pars(23) estimated"


# -----------------------------------
#  PHASE 0 - create initial par file
# -----------------------------------

$program_path bet.frq bet.ini 00.par -makepar

# The diagnostic model fixes the eight grouped fish_pars(22) concentration
# intercepts after they had converged to their upper bound (7). Set all
# fishery copies explicitly before applying the same G8 grouping and flag 69=0.
awk -v concentration="$dm_concentration" '
  /^# extra fishery parameters/ { in_fish = 1; print; next }
  in_fish && /^#/ { print; next }
  in_fish && NF {
    fish_row++
    if (fish_row == 22) {
      if (NF != 33) exit 38
      for (i = 1; i <= NF; i++)
        printf "%s%s", concentration, (i == NF ? "\n" : " ")
      changed = 1
      next
    }
  }
  { print }
  END { if (changed != 1) exit 38 }
' 00.par > 00.dm-fixed.par

# -----------------------
#  PHASE 1 - initial par
# -----------------------

$program_path bet.frq 00.dm-fixed.par 01.par -file - <<PHASE1
# Use default quasi-Newton minimizer
  1 351 0
  1 192 0
# Allow all growth parameters to be fixed during control phase
  1 32 7
# Richards growth settings
  1 226 0
  1 227 0
# Catch conditioned flags
# General activation
  1 373 1  # activate CC with Baranov equation
  1 393 0  # estimate kludged_equilib_coffs and implicit_fm_level_regression_pars
  2 92 2   # specify catch-conditioned option with Baranov equation
# Catch equation bounds
  2 116 70   # value for Zmax_fish in catch equations
  2 189 80   # fraction of Zmax_fish above which penalty is calculated
  1 382 300  # weight for Zmax_fish penalty - set to 300 to avoid triggering Zmax_flag=1
# Deactivate any catch errors flags
  -999 1 0
  -999 4 0
  -999 10 0
  -999 15 0
  -999 13 0
# Survey fisheries defined
# fish flag 92 = round(region sigma * 100), fish flag 94 = allow unequal sigma,
# fish flag 66 = 1: use normalized time-varying relative-variance multipliers from the frequency data.
# 2026 index-fishery sigma settings.
  -29 94 1 -29 92 35 -29 66 1  # Residual-based CPUE R1 maximum-likelihood observation-error estimate=0.354; fixed executed error scale=0.35 (flag 92=35)
  -30 94 1 -30 92 24 -30 66 1  # Residual-based CPUE R2 maximum-likelihood observation-error estimate=0.237; fixed executed error scale=0.24 (flag 92=24)
  -31 94 1 -31 92 21 -31 66 1  # Residual-based CPUE R3 maximum-likelihood observation-error estimate=0.212; fixed executed error scale=0.21 (flag 92=21)
  -32 94 1 -32 92 24 -32 66 1  # Residual-based CPUE R4 maximum-likelihood observation-error estimate=0.239; fixed executed error scale=0.24 (flag 92=24)
  -33 94 1 -33 92 23 -33 66 1  # Residual-based CPUE R5 maximum-likelihood observation-error estimate=0.225; fixed executed error scale=0.23 (flag 92=23)
# Grouping flags for survey CPUE
   -1 99 1
   -2 99 2
   -3 99 3
   -4 99 4
   -5 99 5
   -6 99 6
   -7 99 7
   -8 99 8
   -9 99 9
  -10 99 10
  -11 99 11
  -12 99 12
  -13 99 13
  -14 99 14
  -15 99 15
  -16 99 16
  -17 99 17
  -18 99 18
  -19 99 19
  -20 99 20
  -21 99 21
  -22 99 22
  -23 99 23
  -24 99 24
  -25 99 25
  -26 99 26
  -27 99 27
  -28 99 28
  -29 99 29  # Index R1; shared initial stationary-catchability/likelihood group
  -30 99 29  # Index R2; shared initial stationary-catchability/likelihood group
  -31 99 29  # Index R3; shared initial stationary-catchability/likelihood group
  -32 99 29  # Index R4; shared initial stationary-catchability/likelihood group
  -33 99 29  # Index R5; shared initial stationary-catchability/likelihood group
# Recruitment and initial population settings
  1 149 100        # recruitment deviation penalty
  1 400 6          # final six recruitment deviates set to zero
# Fixed terminal recruitments are arithmetic mean of remaining period (not default geometric mean)
  1 398 1
  2 177 1          # use old totpop scaling method
  2 110 $regional_recruitment_penalty_flag  # regional recruitment-distribution penalty coefficient
  2 32 1           # and estimate totpop parameter
  2 93 4           # set no. of recruitments per year to 4
  2 57 4           # set no. of recruitments per year to 4
  2 94 1 2 128 100  # initial Z = 1.0*M, i.e. initial F = 0
# Likelihood component settings
  1 111 4     # set likelihood function for tags to negative binomial
  1 141 11  # length-frequency likelihood: Dirichlet-multinomial without random effects
  1 139 3     # set likelihood function for WF data to normal
  -999 49 20  # divide LF sample sizes by 20
  -999 50 20  # divide WF sample sizes by 20
# Additional LF/WF sample-size reductions retained from the inherited setup.
# Index fisheries 29-33 are included; extraction labels use the five-region fishery map.
   -1 49 40   -1 50 40
   -2 49 40   -2 50 40
   -4 49 40   -4 50 40
   -6 49 40   -6 50 40
   -7 49 40   -7 50 40
   -8 49 40   -8 50 40
  -10 49 40  -10 50 40
  -29 49 40  -29 50 40
  -30 49 40  -30 50 40
  -31 49 40  -31 50 40
  -32 49 40  -32 50 40
  -33 49 40  -33 50 40
# Tag dynamics settings
  1 33 99    # maximum tag reporting rate for all fisheries is 0.99
  2 96 30    # pool tags after 30 quarters at liberty
# Mixing periods are read from bet.ini tag flags for this step.
  2 198 1    # activate release group reporting rates
  -999 43 0  # estimate tag variance if = 1
  -999 44 0  # group all tags for variance estimation if = 1
# Grouping of fisheries for tag return data, mapped from BET_PHrev_FNL.xlsx.
# New labels with region 4 in the workbook are treated as region 5 here.
   -1 32 1   # LL.WEST.1, old1
   -2 32 2   # LL.EAST.1, old2
   -3 32 3   # LL.US.1, old3
   -4 32 4   # LL.ALL.2, old7
   -5 32 5   # LL.OS.2, old6
   -6 32 6   # LL.ARCH.3, old8
   -7 32 7   # LL.WEST.3, old4
   -8 32 8   # LL.EAST.3, old9
   -9 32 9   # LL.OS.3, old5
  -10 32 10  # LL.ALL.5, old11 + old12 + old29
  -11 32 11  # LL.AU.5, old10 + old27
  -12 32 12  # PS.JP.1, old19
  -13 32 13  # PL.JP.1, old20
  -14 32 14  # HL.ID.2, part of old18
  -15 32 14  # HL.PH.2, part of old18
  -16 32 15  # PL.ALL.2, old28
  -17 32 14  # PS.ID.2, split old24
  -18 32 14  # PS.PH.2, split old24
  -19 32 16  # PS.ASS.2, old30
  -20 32 16  # PS.UNA.2, old31
  -21 32 14  # DOM.ID.2, old23
  -22 32 14  # DOM.PH.2, old17
  -23 32 17  # DOM.VN.2, old32
  -24 32 18  # PL.ALL.WEST.3, old21 + old22
  -25 32 19  # PS.ASS.WEST.3, old13 + old25
  -26 32 20  # PS.ASS.EAST.3, old15
  -27 32 19  # PS.UNA.WEST.3, old14 + old26
  -28 32 20  # PS.UNA.EAST.3, old16
  -29 32 21  # Index R1
  -30 32 21  # Index R2
  -31 32 21  # Index R3
  -32 32 21  # Index R4
  -33 32 21  # Index R5
# Selectivity settings
  -999 3 37  # all selectivities equal for age class 37 and older
  -999 26 2  # evaluate age-based selectivity against scaled mean length-at-age
  -999 57 3  # cubic-spline selectivity
  -999 61 5  # five cubic-spline coefficients by default
  -10 16 1  # F10 LL.ALL.5: penalize decreases in selectivity with age
  -10 56 10000  # weak F10 non-decreasing penalty (1% of the MFCL default)
# Grouping of fisheries with common selectivity, mapped from BET_PHrev_FNL.xlsx.
# Staged run 1 uses 29 contiguous groups: F1-F28 use groups 1-28; F29-F33 initially share group 29.
  -1 24 1  # F1 staged-run-1 selectivity group
  -2 24 2  # F2 staged-run-1 selectivity group
  -3 24 3  # F3 staged-run-1 selectivity group
  -4 24 4  # F4 staged-run-1 selectivity group
  -5 24 5  # F5 staged-run-1 selectivity group
  -6 24 6  # F6 staged-run-1 selectivity group
  -7 24 7  # F7 staged-run-1 selectivity group
  -8 24 8  # F8 staged-run-1 selectivity group
  -9 24 9  # F9 staged-run-1 selectivity group
  -10 24 10  # F10 staged-run-1 selectivity group
  -11 24 11  # F11 staged-run-1 selectivity group
  -12 24 12  # F12 staged-run-1 selectivity group
  -13 24 13  # F13 staged-run-1 selectivity group
  -14 24 14  # F14 staged-run-1 selectivity group
  -15 24 15  # F15 staged-run-1 selectivity group
  -16 24 16  # F16 staged-run-1 selectivity group
  -17 24 17  # F17 staged-run-1 selectivity group
  -18 24 18  # F18 staged-run-1 selectivity group
  -19 24 19  # F19 staged-run-1 selectivity group
  -20 24 20  # F20 staged-run-1 selectivity group
  -21 24 21  # F21 staged-run-1 selectivity group
  -22 24 22  # F22 staged-run-1 selectivity group
  -23 24 23  # F23 staged-run-1 selectivity group
  -24 24 24  # F24 staged-run-1 selectivity group
  -25 24 25  # F25 staged-run-1 selectivity group
  -26 24 26  # F26 staged-run-1 selectivity group
  -27 24 27  # F27 staged-run-1 selectivity group
  -28 24 28  # F28 staged-run-1 selectivity group
  -29 24 29  # F29 staged-run-1 selectivity group
  -30 24 29  # F30 staged-run-1 selectivity group
  -31 24 29  # F31 staged-run-1 selectivity group
  -32 24 29  # F32 staged-run-1 selectivity group
  -33 24 29  # F33 staged-run-1 selectivity group
# Non-decreasing selectivity for the old6-derived longline fishery.
# Selected old-derived longline fisheries set to zero for first two age classes.
  -2 75 2  # F2 youngest age classes fixed at zero selectivity
  -4 75 2  # F4 youngest age classes fixed at zero selectivity
  -5 75 2  # F5 youngest age classes fixed at zero selectivity
  -7 75 2  # F7 youngest age classes fixed at zero selectivity
  -8 75 2  # F8 youngest age classes fixed at zero selectivity
  -9 75 2  # F9 youngest age classes fixed at zero selectivity
  -10 75 2  # F10 youngest age classes fixed at zero selectivity
# Old18 split into HL.ID.2 and HL.PH.2.
# Final exploration applies the youngest-five-age constraint to both split fisheries.
  -14 75 5  # F14 HL.ID.2 youngest age classes fixed at zero selectivity
  -15 75 5  # F15 youngest age classes fixed at zero selectivity
# Age-based spline constraints mapped from old fishery recipes.
  -19 16 0 -19 3 25  # F19 selected revised fishery-specific specification: selectivity-form penalty off
  -25 16 0 -25 3 25  # F25 selected revised fishery-specific specification: selectivity-form penalty off
  -26 16 0 -26 3 25  # F26 selected revised fishery-specific specification: selectivity-form penalty off
  -27 16 0 -27 3 30  # F27 selected revised fishery-specific specification: selectivity-form penalty off
  -17 16 0 -17 3 25  # F17 selected revised fishery-specific specification: selectivity-form penalty off
  -18 16 0 -18 3 25  # F18 selected revised fishery-specific specification: selectivity-form penalty off
  -12 16 0 -12 3 25  # F12 selected revised fishery-specific specification: selectivity-form penalty off
  -13 16 0 -13 3 30  # F13 selected revised fishery-specific specification: selectivity-form penalty off
# Upper-age selectivity constraints mapped from old fishery recipes.
  -22 16 0 -22 3 7  # F22 selected revised fishery-specific specification: selectivity-form penalty off
  -24 16 0 -24 3 25  # F24 selected revised fishery-specific specification: selectivity-form penalty off
  -21 16 0 -21 3 10  # F21 selected revised fishery-specific specification: selectivity-form penalty off
  -16 16 0 -16 3 25  # F16 selected revised fishery-specific specification: selectivity-form penalty off
  -23 16 0 -23 3 6  # F23 selected revised fishery-specific specification: selectivity-form penalty off
# Turn on weighted spline for calculating maturity at age
  2 188 2
# Set Lorenzen M
  2 109 3  # select Lorenzen curve
  1 121 0    # estimate no natural-mortality age_pars(5) coefficients; fix Lorenzen intercept and length slope at incoming .par values
# Filter out comps with input samples less than 50
  1 311 1  # enable tail-compressed observed and predicted length-frequency arrays
  1 301 1   # set tail compression for WF data
  1 313 0  # not read by the DM likelihood; reset to avoid percentage-tail preprocessing, while flag 320 controls DM support
  1 303 0   # proportions in compressed tails for WF data
  1 312 50  # set minimum obs sample size for LF data
  1 302 50  # set minimum obs sample size for WF data
# MFCL 2.2.2.0 growth variance fix
  1 34 0    # set to 1 34 1 for backwards compatibility
  -15 16 0  # F15 selected revised fishery-specific specification: selectivity-form penalty off
  -15 3 25  # F15 terminal spline age and start age for the older-age dome penalty
  -25 61 7  # F25 seven estimated cubic-spline nodes
  -25 75 0  # F25 no youngest age classes forced to near-zero selectivity
  -26 61 7  # F26 seven estimated cubic-spline nodes
  -26 75 0  # F26 no youngest age classes forced to near-zero selectivity
  -1 75 2  # F1 youngest age classes fixed at zero selectivity
  -3 75 2  # F3 youngest age classes fixed at zero selectivity
  -6 75 2  # F6 youngest age classes fixed at zero selectivity
  -11 75 2  # F11 youngest age classes fixed at zero selectivity
  -12 75 2  # F12 youngest age classes fixed at zero selectivity
  -13 75 1  # F13 youngest age classes fixed at zero selectivity
  -29 75 2  # Index R1 youngest age classes fixed at zero selectivity
  -30 75 2  # Index R2 youngest age classes fixed at zero selectivity
  -31 75 2  # Index R3 youngest age classes fixed at zero selectivity
  -32 75 2  # Index R4 youngest age classes fixed at zero selectivity
  -33 75 2  # Index R5 youngest age classes fixed at zero selectivity
  1 320 5  # use tail-compressed DM when the first-to-last-positive observed span contains at least five bins
  1 342 25  # diagnostic-model DM effective-sample-size upper bound
  -1 68 1  # G8PSSET DM group for F1
  -2 68 1  # G8PSSET DM group for F2
  -3 68 1  # G8PSSET DM group for F3
  -4 68 1  # G8PSSET DM group for F4
  -5 68 2  # G8PSSET DM group for F5
  -6 68 1  # G8PSSET DM group for F6
  -7 68 1  # G8PSSET DM group for F7
  -8 68 1  # G8PSSET DM group for F8
  -9 68 2  # G8PSSET DM group for F9
  -10 68 1  # G8PSSET DM group for F10
  -11 68 1  # G8PSSET DM group for F11
  -12 68 3  # G8PSSET DM group for F12
  -13 68 7  # G8PSSET DM group for F13
  -14 68 6  # G8PSSET DM group for F14
  -15 68 6  # G8PSSET DM group for F15
  -16 68 7  # G8PSSET DM group for F16
  -17 68 3  # G8PSSET DM group for F17
  -18 68 3  # G8PSSET DM group for F18
  -19 68 4  # G8PSSET DM group for F19
  -20 68 5  # G8PSSET DM group for F20
  -21 68 7  # G8PSSET DM group for F21
  -22 68 7  # G8PSSET DM group for F22
  -23 68 7  # G8PSSET DM group for F23
  -24 68 7  # G8PSSET DM group for F24
  -25 68 4  # G8PSSET DM group for F25
  -26 68 4  # G8PSSET DM group for F26
  -27 68 5  # G8PSSET DM group for F27
  -28 68 5  # G8PSSET DM group for F28
  -29 68 8  # G8PSSET DM group for F29
  -30 68 8  # G8PSSET DM group for F30
  -31 68 8  # G8PSSET DM group for F31
  -32 68 8  # G8PSSET DM group for F32
  -33 68 8  # G8PSSET DM group for F33
  -999 69 0  # fix grouped fish_pars(22) concentration intercepts at 7
  -999 89 0  # stage relative sample-size exponent fixed at zero
PHASE1

if [ "$seed23_apply" = true ]; then
  mkdir -p "$seed23_audit_dir"
  cp 01.par "$seed23_audit_dir/phase01-before.par"
  seed23_initialize \
    phase1 \
    01.par \
    - \
    "$seed23_audit_dir/phase01-seed23.par" \
    - \
    all \
    1
  cp "$seed23_audit_dir/phase01-seed23.par" 01.par
fi

# ---------
#  PHASE 2
# ---------

if [ "$seed23_apply" = true ]; then
  if $program_path bet.frq 01.par seed23-phase02-probe.par -file - <<SEED23_PHASE2_PROBE
  1 1 100
  1 50 0
  2 113 0
  1 190 1
  -999 89 1
  1 1 0
  1 246 1
SEED23_PHASE2_PROBE
  then
    seed23_probe_status=0
  else
    seed23_probe_status=$?
  fi
  if [ "$seed23_probe_status" -ne 0 ] && [ "$seed23_probe_status" -ne 3 ]; then
    echo "Seed-23 Phase-2 zero-evaluation probe failed with status $seed23_probe_status." >&2
    exit "$seed23_probe_status"
  fi
  if [ ! -s seed23-phase02-probe.par ] || [ ! -s xinit.rpt ]; then
    echo "Seed-23 Phase-2 probe did not create its PAR and xinit report." >&2
    exit 47
  fi
  mv seed23-phase02-probe.par "$seed23_audit_dir/phase02-probe.par"
  cp xinit.rpt "$seed23_audit_dir/phase02-xinit.rpt"
  seed23_initialize \
    deferred \
    01.par \
    "$seed23_audit_dir/phase02-probe.par" \
    "$seed23_audit_dir/phase02-seed23.par" \
    "$seed23_audit_dir/phase02-xinit.rpt" \
    fish_pars23 \
    2
  cp "$seed23_audit_dir/phase02-seed23.par" 01.par
fi

$program_path bet.frq 01.par 02.par -file - <<PHASE2
  1 1 100  # set max. number of function evaluations per phase to 100
  1 50 0   # set convergence criterion to 1
  2 113 0  # scaling init pop - turned off
  1 190 1  # write plot-xxx.par.rep
  -999 89 1  # estimate group-specific DM relative sample-size exponent (CEST)
PHASE2

# ---------
#  PHASE 3
# ---------

$program_path bet.frq 02.par 03.par -file - <<PHASE3
  2 70 1   # activate time series of reg recruitment parameters
  2 71 1   # estimate temporal changes in recruitment distribution
  2 178 1  # constrain regional recruitments
  1 1 200
PHASE3

# ---------
#  PHASE 4
# ---------

$program_path bet.frq 03.par 04.par -file - <<PHASE4
  2 68 1   # estimate movement coefficients
  2 69 1
  2 27 -1  # penalty wt 0.1 computed against prior
PHASE4

# ---------
#  PHASE 5
# ---------

if [ "$seed23_apply" = true ]; then
  if $program_path bet.frq 04.par seed23-phase05-probe.par -file - <<SEED23_PHASE5_PROBE
  -100000 1 1
  -100000 2 1
  -100000 3 1
  -100000 4 1
  -100000 5 1
  1 77 100
  1 78 1
  1 79 240
  1 80 220
  1 81 1
  -29 99 29
  -30 99 30
  -31 99 31
  -32 99 32
  -33 99 33
  -29 94 0
  -30 94 0
  -31 94 0
  -32 94 0
  -33 94 0
  -29 24 29
  -30 24 30
  -31 24 31
  -32 24 32
  -33 24 33
  1 1 0
  1 246 1
SEED23_PHASE5_PROBE
  then
    seed23_probe_status=0
  else
    seed23_probe_status=$?
  fi
  if [ "$seed23_probe_status" -ne 0 ] && [ "$seed23_probe_status" -ne 3 ]; then
    echo "Seed-23 Phase-5 zero-evaluation probe failed with status $seed23_probe_status." >&2
    exit "$seed23_probe_status"
  fi
  if [ ! -s seed23-phase05-probe.par ] || [ ! -s xinit.rpt ]; then
    echo "Seed-23 Phase-5 probe did not create its PAR and xinit report." >&2
    exit 48
  fi
  mv seed23-phase05-probe.par "$seed23_audit_dir/phase05-probe.par"
  cp xinit.rpt "$seed23_audit_dir/phase05-xinit.rpt"
  seed23_initialize \
    deferred \
    04.par \
    "$seed23_audit_dir/phase05-probe.par" \
    "$seed23_audit_dir/phase05-seed23.par" \
    "$seed23_audit_dir/phase05-xinit.rpt" \
    selectivity_coff \
    5
  cp "$seed23_audit_dir/phase05-seed23.par" 04.par
fi

$program_path bet.frq 04.par 05.par -file - <<PHASE5
  -100000 1 1  # estimate
  -100000 2 1  # time-invariant
  -100000 3 1  # distribution
  -100000 4 1  # of
  -100000 5 1  # recruitment
# STAGED MFCL RUN 5: introduce REGW regional scaling and separate regional CPUE groups.
# These controls persist in subsequent runs through the carried parameter file.
  1 77 100  # REGW regional-scaling penalty weight
  1 78 1  # use mean regional-scaling target
  1 79 240  # start bound: 240 periods back from model end, mapping to source period 53
  1 80 220  # end bound: 220 periods back from model end, mapping to source period 72
  1 81 1  # enable the multivariate-normal regional-scaling penalty
  -29 99 29  # Index R1; separate stationary-catchability/likelihood group from staged run 5
  -30 99 30  # Index R2; separate stationary-catchability/likelihood group from staged run 5
  -31 99 31  # Index R3; separate stationary-catchability/likelihood group from staged run 5
  -32 99 32  # Index R4; separate stationary-catchability/likelihood group from staged run 5
  -33 99 33  # Index R5; separate stationary-catchability/likelihood group from staged run 5
  -29 94 0  # Index R1; separate flag-99 group now supplies its own flag-92 error scale
  -30 94 0  # Index R2; separate flag-99 group now supplies its own flag-92 error scale
  -31 94 0  # Index R3; separate flag-99 group now supplies its own flag-92 error scale
  -32 94 0  # Index R4; separate flag-99 group now supplies its own flag-92 error scale
  -33 94 0  # Index R5; separate flag-99 group now supplies its own flag-92 error scale
# STAGED MFCL RUN 5: separate the five regional-index selectivity-sharing groups.
  -29 24 29  # Index R1; separate selectivity coefficient-sharing group from staged run 5
  -30 24 30  # Index R2; separate selectivity coefficient-sharing group from staged run 5
  -31 24 31  # Index R3; separate selectivity coefficient-sharing group from staged run 5
  -32 24 32  # Index R4; separate selectivity coefficient-sharing group from staged run 5
  -33 24 33  # Index R5; separate selectivity coefficient-sharing group from staged run 5
PHASE5

# ---------
#  PHASE 6
# ---------

$program_path bet.frq 05.par 06.par -file - <<PHASE6
  1 240 1  # fit to age-length data
  1 14 1   # estimate von Bertalanffy K
  1 12 1   # estimate mean length of age 1
  1 13 1   # estimate length of age n
  1 1 300  # function evaluations
PHASE6

# ---------
#  PHASE 7
# ---------

$program_path bet.frq 06.par 07.par -file - <<PHASE7
  1 15 1   # estimate overall SD of length-at-age
  1 16 1   # estimate length dependent SD
  1 173 0  # activate independent mean lengths for first 0 age classes
  1 182 0  # penalty weight
  1 184 0  # estimate parameters
  1 1 500  # function evaluations
PHASE7

# ---------
#  PHASE 8
# ---------

$program_path bet.frq 07.par 08.par -file - <<PHASE8
  2 145 1    # use SRR parameters - low penalty for deviation
  2 146 1    # estimate SRR parameters
  2 182 1    # make SRR annual rather than quarterly
  2 161 1    # lognormal bias correction
  2 163 0    # use steepness parameterization of B&H SRR
  1 149 0    # penalty for recruitment devs
  2 147 1    # time period between spawning and recruitment
  2 148 20   # period for MSY calc - last 20 quarters
  2 155 4    # but not including last year
  2 199 212  # start period for SRR estimation/yield is start 1965?
  2 200 6    # end period for SRR estimation is mid 2017
  -999 55 1  # do impact analysis
  2 171 1    # include SRR-based equilibrium recruitment to compute unfished biomass
  1 186 1    # write fishmort and plotq0.rep
  1 187 1    # write temporary_tag_report
  1 188 1    # write ests.rep
  1 189 1    # write .fit files
  1 1 500    # function evaluations
  1 50 -2    # convergence criteria
  2 116 100  # increase F bound for NR to 1.0
PHASE8

# ---------
#  PHASE 9
# ---------

$program_path bet.frq 08.par 09.par -file - <<PHASE9
  2 145 -1   # use SRR parameters - low penalty for deviation
  1 1 500    # function evaluations
  1 50 -2    # convergence criteria
  2 116 300  # increase F bound for NR to 3.0
PHASE9

# ------------------------------------------------------------------
#  TAG-TAU TREATMENT - negative binomial, tau not estimated
# ------------------------------------------------------------------

# Parest flag 111 remains 4 (negative binomial), while fish flags 43/44
# remain zero and fish_pars(4) is not opened as an independent variable.
# All inherited diagnostic-model controls applied above remain unchanged.
$program_path bet.frq 09.par 10.par -file - <<PHASE10_NO_TAU_EST
  1 1 10000
  1 50 $phase10_11_convergence
  1 121 0
PHASE10_NO_TAU_EST

$program_path bet.frq 10.par 11.par -file - <<PHASE11_NO_TAU_EST
  1 1 5000
  1 50 $phase10_11_convergence
  1 121 0
  1 246 1
PHASE11_NO_TAU_EST

final_par=11.par
parest_111=$(awk '/^# The parest_flags/{getline; print $111; exit}' "$final_par")
parest_121=$(awk '/^# The parest_flags/{getline; print $121; exit}' "$final_par")
parest_141=$(awk '/^# The parest_flags/{getline; print $141; exit}' "$final_par")
parest_320=$(awk '/^# The parest_flags/{getline; print $320; exit}' "$final_par")
parest_342=$(awk '/^# The parest_flags/{getline; print $342; exit}' "$final_par")
estimated_tau_count=$(awk '$2 ~ /^fish_pars[(]4[)]/ {n++} END {print n+0}' indepvar.rpt)
dm22_active=$(awk '$2 ~ /^fish_pars[(]22[)]/ {n++} END {print n+0}' indepvar.rpt)
dm23_active=$(awk '$2 ~ /^fish_pars[(]23[)]/ {n++} END {print n+0}' indepvar.rpt)
active_tau_fisheries=$(awk '
  /^# fish flags/ {in_fish=1; next}
  in_fish && /^#/ {exit}
  in_fish && NF {
    fishery++
    active += $43
    if (fishery == 33) {
      print active + 0
      exit
    }
  }
' "$final_par")
final_m=$(awk '
  /^# age_pars/ || /^# age-class related parameters [(]age_pars[)]/ {
    in_age=1
    next
  }
  in_age && /^#/ {next}
  in_age && NF {
    row++
    if (row == 5) {
      print $1
      exit
    }
  }
' "$final_par")

dm_control_summary=$(awk '
  /^# fish flags/ { in_fish=1; next }
  in_fish && /^#/ { exit }
  in_fish && NF {
    n++; groups[$68]=1; flag69 += $69; flag89 += $89
    if (n == 33) exit
  }
  END {
    for (group in groups) group_count++
    print n "," group_count "," flag69 "," flag89
  }
' "$final_par")

if [ "$parest_111" != 4 ] || [ "$parest_121" != 0 ] ||
   [ "$parest_141" != 11 ] || [ "$parest_320" != 5 ] ||
   [ "$parest_342" != "$dm_nmax" ] ||
   [ "$dm22_active" != 0 ] || [ "$dm23_active" != 8 ] ||
   [ "$dm_control_summary" != "33,8,0,33" ] ||
   [ "$estimated_tau_count" != 0 ] || [ "$active_tau_fisheries" != 0 ]; then
  echo "Final fit did not retain the required DM and negative-binomial tau-not-estimated controls." >&2
  exit 44
fi
if ! awk -v observed="$final_m" 'BEGIN {
  expected = -2.54930339768360
  difference = observed - expected
  if (difference < 0) difference = -difference
  exit(difference <= 1e-12 ? 0 : 1)
}'; then
  echo "Fixed Lorenzen natural mortality changed: $final_m" >&2
  exit 45
fi

printf '%s\n' \
  'mode,tag_likelihood,parest111,estimated_tau_count,active_tau_fisheries,parest121,dm_nmax,dm_concentration,dm22_active,dm23_active,parest141,parest320,parest342,final_m,status' \
  "tau-not-estimated,negative-binomial,$parest_111,$estimated_tau_count,$active_tau_fisheries,$parest_121,$dm_nmax,$dm_concentration,$dm22_active,$dm23_active,$parest_141,$parest_320,$parest_342,$final_m,passed" \
  > tag-tau-audit.csv

if [ "$seed23_apply" = true ]; then
  for seed23_phase in 01 02 05; do
    if [ ! -s "$seed23_audit_dir/phase${seed23_phase}-summary.csv" ]; then
      echo "Seed-23 initialization audit is missing Phase $seed23_phase." >&2
      exit 49
    fi
  done
  {
    sed -n '1,2p' "$seed23_audit_dir/phase01-summary.csv"
    sed -n '2p' "$seed23_audit_dir/phase02-summary.csv"
    sed -n '2p' "$seed23_audit_dir/phase05-summary.csv"
  } > seed23-initialization-summary.csv
  sha256sum \
    "$seed23_audit_dir/phase01-before.par" \
    "$seed23_audit_dir/phase01-seed23.par" \
    "$seed23_audit_dir/phase01-mapping.csv" \
    "$seed23_audit_dir/phase02-probe.par" \
    "$seed23_audit_dir/phase02-seed23.par" \
    "$seed23_audit_dir/phase02-mapping.csv" \
    "$seed23_audit_dir/phase05-probe.par" \
    "$seed23_audit_dir/phase05-seed23.par" \
    "$seed23_audit_dir/phase05-mapping.csv" \
    > "$seed23_audit_dir/SHA256SUMS"
  echo "Seed-23 base initialization audit: passed."
fi
exit 0
