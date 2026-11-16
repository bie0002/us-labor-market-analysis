/*
AI adoption, hiring and payroll employment by U.S. industry
Run in Stata 16+. Uses local downloads; no add-ons.
Exports results/AI_Sector_Hiring_and_Jobs.xlsx and PNG charts.
Model estimates are associations. Payroll projections are conditional scenarios.
*/
version 16.0
set more off
local data "C:/Users/BrianEzeonu/Downloads/Labor Market Analysis"
local out "`data'/results"
local charts "`out'/charts"
local book "`out'/AI_Sector_Hiring_and_Jobs.xlsx"

* Forecast settings. The fast adoption path rises by 10 pp over 12 months,
* from the observed sector share, capped at 100%. Baseline holds AI use fixed.
local low_ai_pp 5
local high_ai_pp 10
local asof = td(15nov2026)
local forecast_origin = tm(2026m10)
local minimum_months 8
local start = tm(2017m1)
foreach f in Sector.xlsx jt.industry jt.series jt.data.3.Hires ce.data.0.AllCESSeries {
    capture confirm file "`data'/`f'"
    if _rc {
        display as error "Missing required file: `data'/`f'"
        exit 601
    }
}
capture confirm file "`data'/jt.data.5.Quits"
local has_quits = _rc == 0
capture mkdir "`out'"
capture mkdir "`charts'"

tempfile mapping jtmap jtlabels jtmeta hires quits payroll dates adoption demand panel ///
    coefficients pooled projected gains losses top10 diagnostics monthly ///
    loo stability hiring_base scenario_end scenarios_total scenario_paths

* Use nonoverlapping CES/BTOS categories. A blank JOLTS code means
* BLS publishes hiring only for an incompatible broader industry, or no match.
clear
input byte sid str48 industry str8 ces_code str6 jt_code
21 "Mining, quarrying, and oil and gas extraction" "10210000" ""
22 "Utilities" "44220000" ""
23 "Construction" "20000000" "230000"
31 "Manufacturing" "30000000" "300000"
42 "Wholesale trade" "41420000" "420000"
44 "Retail trade" "42000000" "440000"
48 "Transportation and warehousing" "43000000" ""
51 "Information" "50000000" "510000"
52 "Finance and insurance" "55520000" "520000"
53 "Real estate and rental and leasing" "55530000" "530000"
54 "Professional, scientific, and technical services" "60540000" ""
55 "Management of companies and enterprises" "60550000" ""
56 "Administrative and support and waste services" "60560000" ""
61 "Private educational services" "65610000" "610000"
62 "Health care and social assistance" "65620000" "620000"
71 "Arts, entertainment, and recreation" "70710000" "710000"
72 "Accommodation and food services" "70720000" "720000"
81 "Other services" "80000000" "810000"
end
generate str13 ces_series = "CES" + ces_code + "01"
isid sid
save "`mapping'"
keep if jt_code != ""
isid jt_code
save "`jtmap'"

* Read BLS tab-delimited downloads through a temporary filename with an
* explicit extension, and convert values only after filtering needed series.
capture program drop ai_read_bls
program define ai_read_bls
    version 16.0
    args source lastcol strings
    tempfile raw
    local csv "`raw'.csv"
    copy "`source'" "`csv'"
    capture noisily import delimited using "`csv'", delimiters(tab) ///
        varnames(nonames) rowrange(2) colrange(1:`lastcol') stringcols(`strings') asdouble clear
    local rc = _rc
    capture erase "`csv'"
    if `rc' exit `rc'
end

ai_read_bls "`data'/jt.industry" 2 "1 2"
rename (v1 v2) (jt_code jolts_industry)
replace jt_code = strtrim(jt_code)
isid jt_code
save "`jtlabels'"

ai_read_bls "`data'/jt.series" 8 "1/8"
rename (v1 v2 v3 v4 v5 v6 v7 v8) ///
    (series_id seasonal jt_code state_code area_code size_code element rate_type)
foreach var of varlist _all {
    replace `var' = strtrim(`var')
}
keep if seasonal == "S" & state_code == "00" & area_code == "00000" ///
    & size_code == "00" & rate_type == "R" & inlist(element,"HI","QU")
merge m:1 jt_code using "`jtlabels'", keep(match) nogen
merge m:1 jt_code using "`jtmap'", keep(match) keepusing(sid) nogen
keep series_id sid element
isid series_id
isid sid element
save "`jtmeta'"

foreach series in hires quits {
    if "`series'" == "quits" & !`has_quits' continue
    local filename "jt.data.3.Hires"
    local element "HI"
    if "`series'" == "quits" {
        local filename "jt.data.5.Quits"
        local element "QU"
    }
    ai_read_bls "`data'/`filename'" 4 "1 3 4"
    rename (v1 v2 v3 v4) (series_id year period value)
    keep if inrange(year,2017,year(dofm(`forecast_origin')))
    replace series_id = strtrim(series_id)
    merge m:1 series_id using "`jtmeta'", keep(match) nogen
    keep if element == "`element'"
    generate byte month = real(substr(strtrim(period),2,2))
    keep if inrange(month,1,12)
    generate int tm = ym(year,month)
    keep if inrange(tm,`start',`forecast_origin')
    generate double `series'_rate = real(strtrim(value))
    keep sid tm `series'_rate
    drop if missing(`series'_rate)
    assert _N > 0
    isid sid tm
    save "``series''"
}

ai_read_bls "`data'/ce.data.0.AllCESSeries" 4 "1 3 4"
rename (v1 v2 v3 v4) (ces_series year period value)
keep if inrange(year,2017,year(dofm(`forecast_origin')))
replace ces_series = strtrim(ces_series)
merge m:1 ces_series using "`mapping'", keep(match) nogen
generate byte month = real(substr(strtrim(period),2,2))
keep if inrange(month,1,12)
generate int tm = ym(year,month)
keep if inrange(tm,`start',`forecast_origin')
generate double jobs = 1000 * real(strtrim(value))
keep if jobs > 0 & !missing(jobs)
keep sid industry tm jobs
isid sid tm
xtset sid tm, monthly
generate double payroll_growth_pct = 100 * (ln(jobs) - ln(L.jobs))
generate double annual_log_growth = 100 * (ln(jobs) - ln(L12.jobs))
generate double prior_annual_growth = L12.annual_log_growth
generate double baseline_abs_error_pct = abs(100*(jobs/(L12.jobs*exp(prior_annual_growth/100))-1))
generate double flat_abs_error_pct = abs(100*(jobs/L12.jobs-1))
save "`payroll'"

* BTOS adoption and demand are averaged within reference-end month.
* Keep published waves available at the analysis date. Treat suppressed
* responses as missing. The broader AI wording starts November 17, 2025.
import excel using "`data'/Sector.xlsx", sheet("Collection and Reference Dates") allstring clear
generate long wave = real(strtrim(D))
keep if !missing(wave)
foreach pair in "beg E" "ref H" "pub I" {
    tokenize "`pair'"
    generate double `1' = daily(`2',"MDY")
    replace `1' = daily(`2',"YMD") if missing(`1')
    replace `1' = daily(`2',"DMY") if missing(`1')
    replace `1' = real(`2')-21916 if missing(`1') & inrange(real(`2'),40000,60000)
}
keep wave beg ref pub
isid wave
save "`dates'"

foreach measure in adoption demand {
    local sheet "Response Estimates"
    if "`measure'" == "demand" local sheet "Index Estimates"
    import excel using "`data'/Sector.xlsx", sheet("`sheet'") allstring clear
    unab columns : _all
    local wavecols ""
    foreach col of local columns {
        local header = strtrim(`col'[1])
        if regexm("`header'","^20[0-9][0-9][0-9][0-9]$") {
            rename `col' w_`header'
            local wavecols "`wavecols' w_`header'"
        }
    }
    if "`wavecols'" == "" {
        display as error "No BTOS period columns found in `sheet'."
        exit 459
    }
    if "`measure'" == "adoption" keep if real(B) == 7 & lower(strtrim(E)) == "yes"
    if "`measure'" == "demand" keep if lower(strtrim(B)) == "demand"
    generate byte sid = real(strtrim(A))
    keep sid `wavecols'
    merge 1:1 sid using "`mapping'", keep(match) keepusing(industry) nogen
    assert _N == 18
    drop industry
    reshape long w_, i(sid) j(wave)
    generate double `measure' = real(subinstr(strtrim(w_),"%","",.))
    merge m:1 wave using "`dates'", assert(match using) keep(match) nogen
    keep if !missing(pub,ref,beg) & pub <= `asof'
    if "`measure'" == "adoption" keep if beg >= td(17nov2025)
    generate int tm = mofd(ref)
    collapse (mean) `measure' (count) `measure'_waves=`measure', by(sid tm)
    assert inrange(`measure',0,100) if !missing(`measure')
    isid sid tm
    save "``measure''"
}

use "`payroll'", clear
merge 1:1 sid tm using "`hires'", keep(master match) nogen
if `has_quits' merge 1:1 sid tm using "`quits'", keep(master match) nogen
merge 1:1 sid tm using "`adoption'", keep(master match) nogen
merge 1:1 sid tm using "`demand'", keep(master match) nogen
xtset sid tm, monthly
generate double ai10 = L.adoption/10
generate double prior_demand = L2.demand
if `has_quits' generate double prior_quits = L2.quits_rate
format tm %tmCCYY-NN
save "`panel'"

* Fixed effects compare within industries after adjusting for common months.
* Estimate benchmark pooled models, then one slope per sector with enough data.
* Keep sparse payroll sectors in the scenario with an explicitly pooled slope.
tempname pr sr lr
postfile `pr' str20 outcome str24 specification double effect_per_10pp se ///
    ci_low ci_high int n_observations n_sectors using "`pooled'", replace
postfile `sr' byte sid str20 outcome str20 slope_source double effect_per_10pp se ///
    pooled_effect_per_10pp int sector_months using "`coefficients'", replace
postfile `lr' byte sid str20 outcome int omitted_month double refit_effect ///
    using "`loo'", replace

foreach outcome in hires_rate payroll_growth_pct {
    use "`panel'", clear
    generate byte complete = !missing(`outcome',ai10,prior_demand)
    quietly regress `outcome' c.ai10 i.sid i.tm if complete, vce(cluster sid)
    quietly lincom ai10
    post `pr' ("`outcome'") ("Sector and month FE") (r(estimate)) (r(se)) ///
        (r(lb)) (r(ub)) (e(N)) (e(N_clust))

    quietly regress `outcome' c.ai10 c.prior_demand i.sid i.tm if complete, vce(cluster sid)
    quietly lincom ai10
    local pooled_b = r(estimate)
    local pooled_se = r(se)
    assert !missing(`pooled_b',`pooled_se') & `pooled_se' > 0
    post `pr' ("`outcome'") ("Plus earlier demand") (r(estimate)) (r(se)) ///
        (r(lb)) (r(ub)) (e(N)) (e(N_clust))

    if `has_quits' & "`outcome'" == "hires_rate" {
        quietly regress `outcome' c.ai10 c.prior_demand i.sid i.tm ///
            if complete & !missing(prior_quits), vce(cluster sid)
        quietly lincom ai10
        post `pr' ("`outcome'") ("Demand matched sample") (r(estimate)) (r(se)) ///
            (r(lb)) (r(ub)) (e(N)) (e(N_clust))
        quietly regress `outcome' c.ai10 c.prior_demand c.prior_quits i.sid i.tm ///
            if complete & !missing(prior_quits), vce(cluster sid)
        quietly lincom ai10
        post `pr' ("`outcome'") ("Plus earlier quits") (r(estimate)) (r(se)) ///
            (r(lb)) (r(ub)) (e(N)) (e(N_clust))
    }

    bysort sid: egen int available_months = total(complete)
    by sid: egen double ai_sd = sd(cond(complete,ai10,.))
    generate byte eligible = available_months >= `minimum_months' & ai_sd > 0 & !missing(ai_sd)
    quietly summarize sid if eligible & complete, meanonly
    local ref = r(min)
    assert !missing(`ref')
    quietly regress `outcome' c.ai10##ib`ref'.sid c.prior_demand i.tm ///
        if eligible & complete, vce(robust)
    quietly levelsof sid, local(ids)
    foreach id of local ids {
        quietly summarize available_months if sid == `id', meanonly
        local n = r(max)
        local b = .
        local se = .
        local source "No hiring series"
        if `n' > 0 | "`outcome'" == "payroll_growth_pct" {
            local source "Pooled fallback"
            local b = `pooled_b'
            local se = `pooled_se'
            quietly count if sid == `id' & e(sample)
            if r(N) > 0 {
                if `id' == `ref' capture quietly lincom ai10
                else capture quietly lincom ai10 + `id'.sid#c.ai10
                if !_rc {
                    if !missing(r(se),r(estimate)) & r(se) > 0 {
                        local source "Sector estimate"
                        local b = r(estimate)
                        local se = r(se)
                    }
                }
            }
        }
        post `sr' (`id') ("`outcome'") ("`source'") (`b') (`se') (`pooled_b') (`n')
    }

    * Drop the same month across all sectors; keep the original eligible sectors.
    quietly levelsof tm if eligible & complete, local(model_months)
    foreach omitted of local model_months {
        capture quietly regress `outcome' c.ai10##ib`ref'.sid c.prior_demand i.tm ///
            if eligible & complete & tm != `omitted', vce(robust)
        if _rc continue
        foreach id of local ids {
            quietly count if sid == `id' & e(sample)
            if r(N) < `minimum_months'-1 continue
            if `id' == `ref' capture quietly lincom ai10
            else capture quietly lincom ai10 + `id'.sid#c.ai10
            if _rc continue
            if !missing(r(estimate),r(se)) & r(se) > 0 {
                post `lr' (`id') ("`outcome'") (`omitted') (r(estimate))
            }
        }
    }
}
postclose `pr'
postclose `sr'
postclose `lr'

use "`loo'", clear
generate str10 omitted_period = string(dofm(omitted_month),"%tdMon_CCYY")
drop omitted_month
format refit_effect %12.4f
save "`loo'", replace
collapse (min) loo_low=refit_effect (max) loo_high=refit_effect ///
    (count) loo_refits=refit_effect, by(sid outcome)
save "`stability'"

use "`coefficients'", clear
merge 1:1 sid outcome using "`stability'", keep(master match) nogen
generate str30 stability_flag = "Stable in monthly refits"
replace stability_flag = "Few usable refits" if missing(loo_refits) | loo_refits < 6
replace stability_flag = "Wide monthly refit range" if loo_refits >= 6 & loo_refits < . ///
    & loo_high-loo_low > max(abs(effect_per_10pp),.05)
replace stability_flag = "Sign sensitive" if loo_refits >= 6 & loo_refits < . ///
    & min(loo_low,effect_per_10pp)<0 & max(loo_high,effect_per_10pp)>0
replace stability_flag = "Pooled fallback" if slope_source == "Pooled fallback"
replace stability_flag = "No comparable hiring series" if slope_source == "No hiring series"
format effect_per_10pp pooled_effect_per_10pp se loo_low loo_high %12.4f
merge m:1 sid using "`mapping'", assert(match) keepusing(industry jt_code) nogen
order industry sid outcome slope_source effect_per_10pp se sector_months jt_code
replace slope_source = "No hiring series" if outcome == "hires_rate" & jt_code == ""
sort outcome sid
save "`coefficients'", replace

* Before-AI hiring/payroll slopes, plus simple backtests of the
* 12-month payroll continuation forecast versus unchanged payrolls.
use "`panel'", clear
tempname dp
postfile `dp' byte sid double hiring_pretrend_pp_year payroll_pretrend_pct_year ///
    baseline_mean_abs_pct flat_mean_abs_pct baseline_p80_abs_pct int backtest_months ///
    using "`diagnostics'", replace
quietly levelsof sid, local(ids)
foreach id of local ids {
    local hpre = .
    local ppre = .
    capture quietly regress hires_rate c.tm if sid == `id' & inrange(tm,tm(2023m1),tm(2025m10))
    if !_rc local hpre = 12*_b[tm]
    tempvar logjobs
    quietly generate double `logjobs' = ln(jobs) if sid == `id'
    quietly regress `logjobs' c.tm if sid == `id' & inrange(tm,tm(2023m1),tm(2025m10))
    local ppre = 1200*_b[tm]
    drop `logjobs'
    quietly summarize baseline_abs_error_pct if sid == `id' & tm >= `forecast_origin'-59, meanonly
    local bmae = r(mean)
    local bn = r(N)
    quietly summarize flat_abs_error_pct if sid == `id' & tm >= `forecast_origin'-59 ///
        & !missing(baseline_abs_error_pct), meanonly
    local fmae = r(mean)
    quietly _pctile baseline_abs_error_pct if sid == `id' & tm >= `forecast_origin'-59, p(80)
    post `dp' (`id') (`hpre') (`ppre') (`bmae') (`fmae') (r(r1)) (`bn')
}
postclose `dp'
use "`diagnostics'", clear
merge 1:1 sid using "`mapping'", assert(match) keepusing(industry) nogen
order industry
save "`diagnostics'", replace

* Use each sector's three latest published JOLTS rates, all within six months.
use "`hires'", clear
keep if inrange(tm,`forecast_origin'-5,`forecast_origin')
gsort sid -tm
by sid: keep if _n <= 3
collapse (mean) baseline_hires_rate=hires_rate (count) hires_base_months=hires_rate ///
    (min) hires_base_from=tm (max) hires_base_through=tm, by(sid)
format hires_base_from hires_base_through %tmCCYY-NN
replace baseline_hires_rate = . if hires_base_months < 3
save "`hiring_base'"

* Four paths cross adoption growth (+5/+10 pp) with slope source.
* Sector paths use pooled fallback where no sector slope can be estimated.
use "`panel'", clear
keep if tm == `forecast_origin'
assert _N == 18
assert !missing(jobs,annual_log_growth)
keep sid industry jobs annual_log_growth adoption
rename (jobs adoption) (starting_jobs observed_ai_pct)
merge 1:1 sid using "`diagnostics'", assert(match) keepusing(baseline_p80_abs_pct) nogen
merge 1:1 sid using "`hiring_base'", assert(master match) nogen
preserve
    use "`coefficients'", clear
    keep if outcome == "payroll_growth_pct"
    rename (effect_per_10pp pooled_effect_per_10pp slope_source stability_flag) ///
        (payroll_effect_per_10pp pooled_payroll_per_10pp payroll_slope_source payroll_stability)
    keep sid payroll_effect_per_10pp pooled_payroll_per_10pp payroll_slope_source payroll_stability
    tempfile payrollslopes
    save "`payrollslopes'"
restore
merge 1:1 sid using "`payrollslopes'", assert(match) nogen
preserve
    use "`coefficients'", clear
    keep if outcome == "hires_rate"
    rename (effect_per_10pp pooled_effect_per_10pp slope_source stability_flag) ///
        (hires_effect_per_10pp pooled_hires_per_10pp hires_slope_source hiring_stability)
    replace pooled_hires_per_10pp = . if missing(hires_effect_per_10pp)
    keep sid hires_effect_per_10pp pooled_hires_per_10pp hires_slope_source hiring_stability
    tempfile hiresslopes
    save "`hiresslopes'"
restore
merge 1:1 sid using "`hiresslopes'", assert(match) nogen

expand 4
bysort sid: generate byte scenario_id = _n
generate double target_adoption_add_pp = cond(inlist(scenario_id,1,3),`low_ai_pp',`high_ai_pp')
generate str26 scenario = cond(scenario_id<=2,"Sector slope","Pooled slope") ///
    + " / +" + strtrim(string(target_adoption_add_pp)) + " pp"
generate double applied_payroll_slope = cond(scenario_id<=2,payroll_effect_per_10pp,pooled_payroll_per_10pp)
generate double applied_hiring_slope = cond(scenario_id<=2,hires_effect_per_10pp,pooled_hires_per_10pp)
generate str20 applied_payroll_source = cond(scenario_id<=2,payroll_slope_source,"Pooled sensitivity")
expand 12
bysort sid scenario_id: generate byte horizon = _n
generate int target_tm = `forecast_origin'+horizon
generate str10 target_month = subinstr(string(dofm(target_tm),"%tdMon_CCYY"),"_"," ",.)
generate double extra_adoption_pp = min(100-observed_ai_pct,target_adoption_add_pp*horizon/12) ///
    if !missing(observed_ai_pct)
generate double projected_ai_pct = observed_ai_pct + extra_adoption_pp
generate double lagged_extra_ai_pp = min(100-observed_ai_pct,target_adoption_add_pp*(horizon-1)/12) ///
    if !missing(observed_ai_pct)
generate double monthly_ai_growth_log_pp = applied_payroll_slope * lagged_extra_ai_pp/10
bysort sid scenario_id (horizon): generate double cum_ai_growth = sum(monthly_ai_growth_log_pp)
generate double baseline_jobs = starting_jobs * exp((annual_log_growth*horizon/12)/100)
generate double faster_ai_jobs = baseline_jobs * exp(cum_ai_growth/100) ///
    if !missing(applied_payroll_slope,extra_adoption_pp)
generate double baseline_net_jobs = baseline_jobs - starting_jobs
generate double faster_ai_net_jobs = faster_ai_jobs - starting_jobs
generate double ai_difference_jobs = faster_ai_jobs - baseline_jobs

* Keep implied rates visible, but withhold gross-hire counts across an entire
* sector/scenario path if any month implies a negative rate.
generate double hires_rate_shift_pp = applied_hiring_slope * lagged_extra_ai_pp/10
generate double implied_hires_rate = baseline_hires_rate + hires_rate_shift_pp
generate byte invalid_hires_month = implied_hires_rate < 0 if !missing(implied_hires_rate)
bysort sid scenario_id: egen byte invalid_hires_path = max(invalid_hires_month)
bysort sid scenario_id: egen double minimum_implied_hires_rate = min(implied_hires_rate)
generate str30 hiring_feasibility = "Rates at or above zero" if invalid_hires_path == 0
replace hiring_feasibility = "Below 1%; use caution" if invalid_hires_path == 0 & minimum_implied_hires_rate < 1
replace hiring_feasibility = "Negative rate; counts withheld" if invalid_hires_path == 1
replace hiring_feasibility = "No usable hiring rate" if missing(invalid_hires_path)
generate double gross_hires_delta = baseline_jobs * (implied_hires_rate-baseline_hires_rate)/100 ///
    if invalid_hires_path == 0
bysort sid scenario_id (horizon): generate double gross_hires_delta_ytd = sum(gross_hires_delta)
replace gross_hires_delta_ytd = . if invalid_hires_path != 0
assert missing(gross_hires_delta) & missing(gross_hires_delta_ytd) if invalid_hires_path != 0
assert abs(faster_ai_net_jobs-baseline_net_jobs-ai_difference_jobs)<.01 if !missing(ai_difference_jobs)
assert _N == 18*4*12
format *slope *_per_10pp *_pp *_pct *_rate %12.4f
format *jobs gross_hires_delta* %15.0fc
order industry scenario target_month horizon baseline_net_jobs faster_ai_net_jobs ai_difference_jobs ///
    payroll_stability hiring_feasibility
save "`monthly'"

* Use a common set of sectors for totals across all four scenarios.
bysort sid: egen byte coverage = count(ai_difference_jobs)
preserve
    keep if coverage == 48
    collapse (sum) baseline_net_jobs faster_ai_net_jobs ai_difference_jobs ///
        (count) sectors_in_total=sid, by(scenario_id scenario target_month target_tm horizon)
    assert _N == 48
    save "`scenario_paths'"
    keep if horizon == 12
    egen double sensitivity_low_jobs = min(ai_difference_jobs)
    egen double sensitivity_high_jobs = max(ai_difference_jobs)
    order scenario target_month sectors_in_total baseline_net_jobs faster_ai_net_jobs ///
        ai_difference_jobs sensitivity_low_jobs sensitivity_high_jobs
    save "`scenarios_total'"
restore

keep if horizon == 12
generate double baseline_error_end_low = baseline_jobs * max(0,1-baseline_p80_abs_pct/100)
generate double baseline_error_end_high = baseline_jobs * (1+baseline_p80_abs_pct/100)
bysort sid: egen double sensitivity_low_jobs = min(ai_difference_jobs)
bysort sid: egen double sensitivity_high_jobs = max(ai_difference_jobs)
generate double absolute_ai_difference = abs(ai_difference_jobs)
assert _N == 18*4
save "`scenario_end'"

* Rankings use the +10-point sector-slope path; sensitivity columns show
* the spread across all four specifications for the same industry.
keep if scenario_id == 2
assert _N == 18
order industry target_month baseline_net_jobs faster_ai_net_jobs ai_difference_jobs ///
    sensitivity_low_jobs sensitivity_high_jobs payroll_stability hiring_feasibility
gsort -faster_ai_net_jobs
save "`projected'"

preserve
    drop if missing(ai_difference_jobs)
    assert _N >= 10
    gsort -absolute_ai_difference sid
    keep in 1/10
    generate byte rank = _n
    order rank
    save "`top10'"
restore
preserve
    keep if faster_ai_net_jobs > 0 & !missing(faster_ai_net_jobs)
    if _N > 0 {
        gsort -faster_ai_net_jobs sid
        if _N > 10 keep in 1/10
    }
    generate byte rank = _n
    order rank
    save "`gains'"
restore
keep if faster_ai_net_jobs < 0
if _N > 0 {
    gsort faster_ai_net_jobs sid
    if _N > 10 keep in 1/10
}
generate byte rank = _n
order rank
save "`losses'"

clear
input str30 topic str244 detail
"AI interpretation" "Estimates are within-industry associations, with national month effects. Reverse causality and other industry shocks may remain. Rankings are scenario outputs and not causal job-loss estimates."
"Model outcomes" "Separate regressions for seasonally adjusted JOLTS hires rates (percent) and CES net payroll growth (monthly log percent). Net jobs come from CES, not hires."
"Predictor and controls" "A 10-point difference in prior-month BTOS AI use, sector and month effects, and BTOS demand two months earlier. Optional earlier quits control is shown for hiring if that file is available."
"Survey measure" "BTOS Question 7 Yes response. Uses published waves with broader wording from November 17, 2025. Averages available waves by reference-end month. Suppressed estimates are missing."
"Sector slopes" "Industry interactions give exploratory sector slopes. A pooled fallback is used when fewer than eight usable observations or no estimable slope. Industry robust SEs do not account for serial dependence."
"Pooled uncertainty" "Pooled regressions use industry-clustered standard errors. The number of sectors is small; treat intervals as approximate. The short common AI period limits sensitivity analysis."
"Coverage" "18 matched BTOS/CES private industries; 12 also have a compatible JOLTS hires series. Agriculture and public administration have different coverage. Other hiring aggregates are not assigned to individual sectors."
"Baseline" "Carries each sector's trailing 12-month CES log growth forward. Forecast origin is October 2026, and the baseline assumes no incremental AI shock."
"Higher AI paths" "Adoption rises linearly by 5 or 10 points, capped at 100%, with a sector or pooled slope. Each month's growth adjustment uses the prior month's extra adoption."
"Model sensitivity" "Ranges span four scenarios, not confidence intervals. Totals cover only industries with all four complete paths. Rankings use +10 points with sector slopes and pooled fallback."
"Refit flags" "Models omit one month at a time. A flag shows sign changes, fewer than six usable refits, or a refit range wider than the larger of the full estimate's magnitude and 0.05 points."
"Total interpretation" "The combined scenario difference covers only matched industries. Month fixed effects absorb shared movements; this model does not identify an economy-wide AI effect."
"Rankings" "Top 10 ranks absolute jobs difference from baseline. Separate tabs show up to 10 positive and 10 negative net payroll changes under the higher AI scenario."
"Hiring approximation" "Baseline hiring is the mean of the latest three published JOLTS rates within six months. Apply the model shift to get the implied rate. A negative rate suppresses gross hires counts for the full path."
"Gross hires" "When rates are feasible, the difference equals the rate change times baseline CES payrolls. This is approximate and differs from net jobs. Missing rates produce no gross count."
"Pretrends and errors" "Jan 2023 to Oct 2025 slopes are descriptive checks. Backtest errors compare trailing growth and flat 12-month payroll forecasts. Baseline bands use past absolute errors and exclude AI uncertainty."
"Sources" "Census BTOS Sector.xlsx; BLS JOLTS industry hires and optional quits, series and industry code files; BLS CES seasonally adjusted payroll history."
end
export excel using "`book'", sheet("Readme") firstrow(variables) replace

local datasets "scenarios_total top10 gains losses projected scenario_end monthly coefficients pooled loo diagnostics panel mapping scenario_paths"
local sheets "Scenario_Totals Top10_AI_Difference Top10_Net_Gains Top10_Net_Losses All_Sector_Forecasts Scenario_Comparison Monthly_Payroll_Scenarios Sector_Models Pooled_Models Leave_One_Month_Out Pretrends_Backtest Model_Panel Industry_Crosswalk Scenario_Paths"
local tab = 0
foreach dataset of local datasets {
    local ++tab
    local sheet : word `tab' of `sheets'
    use "``dataset''", clear
    if _N == 0 {
        clear
        set obs 1
        generate str72 note = "No sectors meet the sign filter for this ranking."
    }
    export excel using "`book'", sheet("`sheet'", replace) firstrow(variables)
    * Keep the exported coefficients numeric and display four decimals in Excel.
    if inlist("`dataset'","projected","scenario_end","coefficients","pooled","loo","top10","gains","losses") {
        putexcel set "`book'", sheet("`sheet'") modify
        local lastrow = _N + 1
        local column = 0
        foreach v of varlist _all {
            local ++column
            if regexm("`v'","(_per_10pp$|^loo_low$|^loo_high$|^refit_effect$|^applied_.*_slope$)") {
                local head = cond(`column'>26,char(64+floor((`column'-1)/26)),"")
                local col = "`head'" + char(65+mod(`column'-1,26))
                putexcel `col'2:`col'`lastrow', nformat("0.0000")
            }
        }
        putexcel clear
    }
}

* Figures emphasize the +10-point sector path, with all four paths shown
* in the sensitivity figures. All jobs axes are in thousands.
* Short labels are for figures only; workbooks retain full industry names.
capture program drop ai_chart_labels
program define ai_chart_labels
    generate str48 chart_industry = industry
    replace chart_industry = "Health care & social assistance" if sid == 62
    replace chart_industry = "Accommodation & food services" if sid == 72
    replace chart_industry = "Arts, entertainment & recreation" if sid == 71
    replace chart_industry = "Admin., support & waste services" if sid == 56
    replace chart_industry = "Professional & technical services" if sid == 54
    replace chart_industry = "Real estate & leasing" if sid == 53
    replace chart_industry = "Private education" if sid == 61
    replace chart_industry = "Transportation & warehousing" if sid == 48
    replace chart_industry = "Management of companies" if sid == 55
    replace chart_industry = "Mining, oil & gas" if sid == 21
end

use "`top10'", clear
ai_chart_labels
generate double jobs_difference_k = ai_difference_jobs/1000
generate double baseline_net_k = baseline_net_jobs/1000
generate double faster_ai_net_k = faster_ai_net_jobs/1000
generate double low_k = sensitivity_low_jobs/1000
generate double high_k = sensitivity_high_jobs/1000

graph hbar (asis) jobs_difference_k, over(chart_industry, sort(rank) label(labsize(vsmall))) ///
    bar(1,color(navy)) yline(0,lcolor(gs10)) ytitle("Jobs difference from baseline (thousands)") ///
    title("Largest 12-month payroll differences") ///
    subtitle("+10-point adoption scenario with sector slopes", size(small)) ///
    note("Ranked by absolute difference. Estimates are conditional and exploratory.") ///
    graphregion(color(white) margin(6 5 4 5)) xsize(13) ysize(8)
graph export "`charts'/ai_top10_payroll_difference.png", width(2400) replace

graph hbar (asis) baseline_net_k faster_ai_net_k, ///
    over(chart_industry, sort(rank) label(labsize(vsmall))) ///
    bar(1,color(gs9)) bar(2,color(navy)) yline(0,lcolor(gs10)) ///
    ytitle("Net jobs from October 2026 (thousands)") ///
    title("Which industries add or lose jobs?", size(medium)) ///
    subtitle("12-month change for the ten largest differences", size(small)) ///
    legend(order(1 "Baseline" 2 "Higher AI (+10 points)") position(6) ring(1) cols(2) size(small)) ///
    graphregion(color(white) margin(6 5 4 5)) xsize(13) ysize(9)
graph export "`charts'/ai_net_jobs_baseline_vs_scenario.png", width(2400) replace

sort rank
capture label drop ai_chart_rank
forvalues row = 1/`=_N' {
    local industry_label = chart_industry[`row']
    if `row' == 1 label define ai_chart_rank `row' "`industry_label'", replace
    else label define ai_chart_rank `row' "`industry_label'", add
}
label values rank ai_chart_rank
twoway (rspike low_k high_k rank, horizontal lcolor(gs9) lwidth(medthick)) ///
    (scatter rank jobs_difference_k, mcolor(navy) msymbol(D)), ///
    ylabel(1(1)10,valuelabel angle(0) labsize(vsmall)) yscale(reverse) ///
    xline(0,lcolor(gs10)) ytitle("") xtitle("Jobs difference from baseline (thousands)") ///
    title("Sensitivity of projected payroll differences", size(medium)) ///
    legend(order(1 "Four-scenario range" 2 "Sector slopes, +10 points") position(6) ring(1) cols(2) size(small)) ///
    note("Ranges reflect scenario assumptions, not statistical uncertainty.", size(vsmall)) ///
    graphregion(color(white) margin(6 5 4 5)) xsize(13) ysize(8)
graph export "`charts'/ai_top10_sensitivity.png", width(2400) replace

use "`scenario_paths'", clear
generate double baseline_k = baseline_net_jobs/1000
generate double scenario_k = faster_ai_net_jobs/1000
quietly summarize sectors_in_total, meanonly
local sectors_in_chart = r(min)
twoway (line baseline_k horizon if scenario_id==1, sort lcolor(gs6) lpattern(dash)) ///
    (line scenario_k horizon if scenario_id==1, sort lcolor(navy) lpattern(dash)) ///
    (line scenario_k horizon if scenario_id==2, sort lcolor(navy) lwidth(medthick)) ///
    (line scenario_k horizon if scenario_id==3, sort lcolor(dkgreen) lpattern(dash)) ///
    (line scenario_k horizon if scenario_id==4, sort lcolor(dkgreen) lwidth(medthick)), ///
    xlabel(1(1)12) yline(0,lcolor(gs10)) xtitle("Months after October 2026") ///
    ytitle("Net jobs (thousands)", size(small) margin(small)) ///
    title("Projected jobs under four AI scenarios", size(medium)) ///
    subtitle("Combined change across `sectors_in_chart' matched industries", size(small)) ///
    legend(order(1 "Baseline" 2 "Sector +5 points" 3 "Sector +10 points" ///
    4 "Pooled +5 points" 5 "Pooled +10 points") position(6) ring(1) cols(3) size(small)) ///
    graphregion(color(white) margin(7 5 4 5)) xsize(12) ysize(7)
graph export "`charts'/ai_combined_scenario_paths.png", width(2400) replace

use "`projected'", clear
ai_chart_labels
keep if !missing(baseline_hires_rate,minimum_implied_hires_rate)
if _N > 0 {
    graph hbar (asis) baseline_hires_rate minimum_implied_hires_rate, ///
        over(chart_industry, sort(2) label(labsize(vsmall))) ///
        bar(1,color(gs9)) bar(2,color(maroon)) yline(0,lcolor(gs10)) ///
        ytitle("Monthly hires rate (%)") ///
        title("Which hiring estimates approach zero?", size(medium)) ///
        subtitle("+10-point adoption scenario with sector slopes", size(small)) ///
        legend(order(1 "Recent hiring rate" 2 "Lowest scenario rate") position(6) ring(1) cols(2) size(small)) ///
        note("Negative implied rates suppress gross-hire counts.", size(vsmall)) ///
        graphregion(color(white) margin(6 5 4 5)) xsize(13) ysize(9)
    graph export "`charts'/ai_hiring_rate_feasibility.png", width(2400) replace
}

capture program drop ai_chart_labels
capture program drop ai_read_bls
display as result "Workbook saved: `book'"
display as result "Charts saved: `charts'"
