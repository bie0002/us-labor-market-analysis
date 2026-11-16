/*
U.S. labor-market tables, January-October 2026
Run in Stata 16+ with the files already downloaded. No add-ons needed.
The do-file replaces Labor_Market_Tables_2026.xlsx in the results folder.
All raw inputs stay untouched. Data in Stata's memory will be replaced.
*/

version 16.0
set more off

* Change this line if you move your downloaded files.
local data "C:/Users/BrianEzeonu/Downloads/Labor Market Analysis"
local results "`data'/results"
local book "`results'/Labor_Market_Tables_2026.xlsx"
local months "jan feb mar apr may jun jul aug sep oct"

foreach filename in ce.data.0.AllCESSeries ce.series cps_industry_codes.csv {
    capture confirm file "`data'/`filename'"
    if _rc {
        display as error "Missing input: `data'/`filename'"
        exit 601
    }
}
foreach m of local months {
    capture confirm file "`data'/`m'26pub.csv"
    if _rc {
        display as error "Missing input: `data'/`m'26pub.csv"
        exit 601
    }
}
capture mkdir "`results'"
local charts "`results'/charts"
capture mkdir "`charts'"

tempfile sectors catalog ces ranks crosswalk people lfp lfp_oct top_trend growth ///
    composition comp_oct leaders benchmarks observed annualcatalog ceshist cpshist annualcps ytdcps annualces ytdces top5sex

* 1. CES industry comparison: mutually exclusive BLS release table B-1 sectors.
*    Exclude combined categories such as private education and health services
*    because their components are already in the comparison.
clear
input byte sector_id str8 industry_code str48 industry
 1 "10000000" "Mining and logging"
 2 "20000000" "Construction"
 3 "30000000" "Manufacturing"
 4 "41420000" "Wholesale trade"
 5 "42000000" "Retail trade"
 6 "43000000" "Transportation and warehousing"
 7 "44220000" "Utilities"
 8 "50000000" "Information"
 9 "55000000" "Financial activities"
10 "60000000" "Professional and business services"
11 "65610000" "Private educational services"
12 "65620001" "Health care"
13 "65624000" "Social assistance"
14 "70000000" "Leisure and hospitality"
15 "80000000" "Other services"
16 "90000000" "Government"
end
generate str13 series_id = "CES" + industry_code + "01"
isid series_id
save "`sectors'"

import delimited using "`data'/ce.series", delimiters(tab) varnames(nonames) rowrange(2) ///
    colrange(1:6) stringcols(1) clear
rename (v1 v6) (series_id series_title)
replace series_id = strtrim(series_id)
keep series_id series_title
merge 1:1 series_id using "`sectors'", keep(match using)
assert _merge == 3
assert _N == 16
drop _merge
save "`catalog'"

* Add total nonfarm for historical context, outside the industry ranking.
preserve
    local national_row = _N + 1
    set obs `national_row'
    replace sector_id = 0 in `national_row'
    replace industry = "Total nonfarm" in `national_row'
    replace series_id = "CES0000000001" in `national_row'
    save "`annualcatalog'"
restore

* Read only series ID, year, period and value from the bulk file.
display as text "Reading CES payroll data; this is the largest input."
* Stata can append .csv to the BLS bulk filename even when it exists.
* Use an explicit extension for import and keep the tab delimiter.
tempfile ces_import
local ces_import_csv "`ces_import'.csv"
copy "`data'/ce.data.0.AllCESSeries" "`ces_import_csv'"
capture noisily import delimited using "`ces_import_csv'", delimiters(tab) ///
    varnames(nonames) rowrange(2) colrange(1:4) stringcols(1 3) asdouble clear
local ces_import_rc = _rc
capture erase "`ces_import_csv'"
if `ces_import_rc' {
    exit `ces_import_rc'
}
rename (v1 v2 v3 v4) (series_id year period value)
keep if inrange(year,2001,2026) & substr(strtrim(series_id), 1, 3) == "CES"
replace series_id = strtrim(series_id)
generate byte month_no = real(substr(strtrim(period), 2, 2))
keep if inrange(month_no,1,12) & (year < 2026 | month_no <= 10)
merge m:1 series_id using "`annualcatalog'", keep(match) nogen
* The bulk file can import value as text. Convert the selected payroll rows
* before the arithmetic and let Stata report any nonnumeric entries.
capture confirm numeric variable value
if _rc {
    destring value, replace
}
confirm numeric variable value
recast double value
assert !missing(value)
isid sector_id year month_no
rename value jobs_thousands
save "`ceshist'"
* December is the reference level. January is a measured monthly change.
keep if sector_id > 0 & (year == 2026 | (year == 2025 & month_no == 12))
assert _N == 176
bysort sector_id (year month_no): assert _N == 11 & year[1] == 2025 & month_no[1] == 12
by sector_id: assert year[_N] == 2026 & month_no[_N] == 10
by sector_id: generate double dec_jobs_thousands = jobs_thousands[1]
by sector_id: generate double oct_jobs_thousands = jobs_thousands[_N]
by sector_id: generate double monthly_change_thousands = ///
    round(jobs_thousands - jobs_thousands[_n-1], .1) if _n > 1
generate double change_since_dec_thousands = round(jobs_thousands - dec_jobs_thousands, .1)
generate double net_jobs_added_thousands = round(oct_jobs_thousands - dec_jobs_thousands, .1)
generate double dec_oct_pct_change = 100 * (oct_jobs_thousands / dec_jobs_thousands - 1)
keep if year == 2026
assert _N == 160
assert monthly_change_thousands == change_since_dec_thousands if month_no == 1
isid sector_id month_no
generate str7 month = "2026-" + string(month_no, "%02.0f")
save "`ces'"

keep if month_no == 10
gsort -net_jobs_added_thousands sector_id
generate byte growth_rank = _n
keep sector_id growth_rank
save "`ranks'"

use "`ces'", clear
merge m:1 sector_id using "`ranks'", assert(match) nogen
preserve
    keep if month_no == 10
    sort growth_rank
    keep growth_rank industry series_id dec_jobs_thousands oct_jobs_thousands ///
        net_jobs_added_thousands dec_oct_pct_change
    order growth_rank industry series_id dec_jobs_thousands oct_jobs_thousands ///
        net_jobs_added_thousands dec_oct_pct_change
    save "`growth'"
restore
keep if growth_rank <= 5
sort growth_rank month_no
keep growth_rank industry month series_id jobs_thousands monthly_change_thousands ///
    change_since_dec_thousands
order growth_rank industry month series_id jobs_thousands monthly_change_thousands ///
    change_since_dec_thousands
save "`top_trend'"

* 2. Census industry lookup. The downloaded 2026 file has the Census code in
*    column 3 and the NAICS equivalent in column 4. Use detailed rows and the
*    stand-alone construction code, excluding headings, ranges, and notes.
import delimited using "`data'/cps_industry_codes.csv", varnames(nonames) ///
    stringcols(_all) encoding("UTF-8") clear
keep if v1 == "detail" | (v1 == "sector" & strtrim(v3) == "0770")
* The published file lists code 7570 twice with the same description.
keep v2 v3 v4
drop if strtrim(v3) == ""
duplicates drop v2 v3 v4, force
generate int peio1icd = real(strtrim(v3))
assert !missing(peio1icd)
isid peio1icd
generate byte census_sector = .
replace census_sector = 1 if peio1icd == 270 | inrange(peio1icd,370,490)
replace census_sector = 2 if peio1icd == 770
replace census_sector = 3 if inrange(peio1icd,1070,3990)
replace census_sector = 4 if inrange(peio1icd,4070,4590)
replace census_sector = 5 if inrange(peio1icd,4670,5791)
replace census_sector = 6 if inrange(peio1icd,6070,6390)
replace census_sector = 7 if inrange(peio1icd,570,690)
replace census_sector = 8 if inrange(peio1icd,6471,6781)
replace census_sector = 9 if inrange(peio1icd,6870,7190)
replace census_sector = 10 if inrange(peio1icd,7270,7790)
replace census_sector = 11 if inrange(peio1icd,7860,7890)
replace census_sector = 12 if inrange(peio1icd,7970,8290)
replace census_sector = 13 if inrange(peio1icd,8370,8470)
replace census_sector = 14 if inrange(peio1icd,8560,8690)
replace census_sector = 15 if inrange(peio1icd,8770,9280)
* Private households (9290) are outside CES coverage. Government is identified
* by class of worker, since public workers can be in several CPS industries.
keep peio1icd census_sector
save "`crosswalk'"

* 3. Stack civilian respondents age 16+ from January through October.
*    PWCMPWGT is the CPS composited final weight, stored with four implied
*    decimal places in the Census public-use CSV.
local month_index = 0
foreach m of local months {
    local ++month_index
    display as text "Reading CPS: `m' 2026"
    import delimited using "`data'/`m'26pub.csv", varnames(1) asdouble case(lower) clear
    keep hryear4 hrmonth prpertyp prtage pesex ptdtrace pehspnon pemlr ///
        pwcmpwgt peio1icd peio1cow
    keep if prpertyp == 2 & inrange(prtage,16,99) & inrange(pemlr,1,7) ///
        & pwcmpwgt > 0 & !missing(pwcmpwgt)
    assert _N > 0
    assert hryear4 == 2026 & hrmonth == `month_index'
    generate str7 month = "2026-" + string(hrmonth, "%02.0f")
    generate double weight = pwcmpwgt / 10000
    generate byte labor_force = inrange(pemlr,1,4)
    generate byte employed = inrange(pemlr,1,2)
    drop hryear4 hrmonth prpertyp pwcmpwgt pemlr
    if `month_index' > 1 {
        append using "`people'"
    }
    save "`people'", replace
}

generate str12 age_group = "55+"
replace age_group = "16-24" if prtage < 25
replace age_group = "25-54" if inrange(prtage,25,54)
generate str12 sex = "Unknown"
replace sex = "Men" if pesex == 1
replace sex = "Women" if pesex == 2
generate str42 race = "Unknown"
replace race = "White alone" if ptdtrace == 1
replace race = "Black alone" if ptdtrace == 2
replace race = "American Indian or Alaska Native alone" if ptdtrace == 3
replace race = "Asian alone" if ptdtrace == 4
replace race = "Native Hawaiian or Pacific Islander alone" if ptdtrace == 5
replace race = "Two or more races" if inrange(ptdtrace,6,26)
generate str22 ethnicity = "Unknown"
replace ethnicity = "Hispanic or Latino" if pehspnon == 1
replace ethnicity = "Not Hispanic or Latino" if pehspnon == 2
generate str60 race_sex = race + " / " + sex
merge m:1 peio1icd using "`crosswalk'", keep(master match) nogen
generate byte sector_id = census_sector if employed == 1 & inlist(peio1cow,4,5,6)
replace sector_id = 16 if employed == 1 & inlist(peio1cow,1,2,3)
save "`people'", replace

* 4. Participation rates: pooled population counts within each month and cell.
*    Export national totals, each dimension separately, and age x sex x race.
generate double weighted_labor_force = weight * labor_force
generate double weighted_employed = weight * employed
generate double weighted_unemployed = weight * (labor_force - employed)
generate double sample_n = 1
foreach dimension in overall age_group sex race race_sex age_sex_race {
    preserve
        local keys ""
        if inlist("`dimension'", "age_group", "sex", "race") local keys "`dimension'"
        if "`dimension'" == "race_sex" local keys "sex race"
        if "`dimension'" == "age_sex_race" local keys "age_group sex race"
        collapse (sum) civilian_pop=weight labor_force_pop=weighted_labor_force ///
            employed_pop=weighted_employed unemployed_pop=weighted_unemployed ///
            sample_n, by(month `keys')
        generate str16 breakdown = "`dimension'"
        foreach field in age_group sex race {
            capture confirm variable `field'
            if _rc generate str42 `field' = "All"
        }
        if "`dimension'" != "overall" {
            append using "`lfp'"
        }
        save "`lfp'", replace
    restore
}
use "`lfp'", clear
generate double participation_pct = 100 * labor_force_pop / civilian_pop
assert inrange(participation_pct,0,100) & civilian_pop > 0
generate double employment_pct = 100 * employed_pop / civilian_pop
generate double unemployment_pct = 100 * unemployed_pop / labor_force_pop if labor_force_pop > 0
assert abs(labor_force_pop - employed_pop - unemployed_pop) < .01
foreach metric in participation employment unemployment {
    bysort breakdown age_group sex race: egen double january = ///
        max(cond(month == "2026-01", `metric'_pct, .))
    generate double `metric'_change_pp = `metric'_pct - january
    drop january
}
format *_pct *_pp %9.2f
format civilian_pop labor_force_pop %15.0fc
sort month breakdown age_group sex race
order month breakdown age_group sex race participation_pct participation_change_pp ///
    unemployment_pct unemployment_change_pp employment_pct employment_change_pp ///
    civilian_pop labor_force_pop employed_pop unemployed_pop sample_n
save "`lfp'", replace
keep if month == "2026-10"
save "`lfp_oct'"

* 5. Representation benchmarks and workforce composition.
* Each share uses the same month, CPS weight and demographic definitions.
* The comparable benchmark is all CPS workers mapped to the CES private
* sectors, or all federal, state and local government workers for government.
use "`people'", clear
generate double private_weight = weight * inrange(sector_id,1,15)
generate double government_weight = weight * (sector_id == 16)
foreach field in age_group sex race ethnicity race_sex {
    preserve
        collapse (sum) group_population=weight group_private=private_weight ///
            group_government=government_weight, by(month `field')
        rename `field' demographic_group
        bysort month: egen double population_total = total(group_population)
        by month: egen double private_total = total(group_private)
        by month: egen double government_total = total(group_government)
        generate double population_share_pct = 100 * group_population / population_total
        generate double private_share_pct = 100 * group_private / private_total
        generate double government_share_pct = 100 * group_government / government_total
        keep month demographic_group population_share_pct private_share_pct government_share_pct
        isid month demographic_group
        save "`benchmarks'", replace
    restore

    preserve
        keep if !missing(sector_id)
        merge m:1 sector_id using "`catalog'", assert(match using) keep(match) keepusing(industry) nogen
        merge m:1 sector_id using "`ranks'", assert(match using) keep(match) nogen
        keep if growth_rank <= 5
        generate double sample_n = 1
        collapse (sum) estimated_workers=weight sample_n, ///
            by(month growth_rank sector_id industry `field')
        rename `field' demographic_group
        save "`observed'", replace
        collapse (sum) industry_workers=estimated_workers, by(month growth_rank sector_id industry)
        assert _N == 50
        joinby month using "`benchmarks'"
        merge 1:1 month growth_rank demographic_group using "`observed'", ///
            assert(master match) keepusing(estimated_workers sample_n)
        replace estimated_workers = 0 if _merge == 1
        replace sample_n = 0 if _merge == 1
        drop _merge
        generate str12 dimension = "`field'"
        generate double industry_share_pct = 100 * estimated_workers / industry_workers
        egen double share_check = total(industry_share_pct), by(month growth_rank)
        assert abs(share_check - 100) < .0001
        drop share_check
        generate str30 workforce_benchmark = "Comparable private workforce"
        replace workforce_benchmark = "Government workforce" if sector_id == 16
        generate double workforce_share_pct = cond(sector_id == 16, government_share_pct, private_share_pct)
        generate double population_gap_pp = industry_share_pct - population_share_pct
        generate double workforce_gap_pp = industry_share_pct - workforce_share_pct
        generate double population_rep_ratio = industry_share_pct / population_share_pct if population_share_pct > 0
        generate double workforce_rep_ratio = industry_share_pct / workforce_share_pct if workforce_share_pct > 0
        egen double highest_known = max(cond(strpos(demographic_group,"Unknown") == 0, estimated_workers, .)), ///
            by(month growth_rank)
        generate byte largest_group = strpos(demographic_group,"Unknown") == 0 & ///
            estimated_workers == highest_known & estimated_workers > 0
        drop highest_known sector_id private_share_pct government_share_pct
        if "`field'" != "age_group" {
            append using "`composition'"
        }
        save "`composition'", replace
    restore
}
use "`composition'", clear
format *_pct *_pp *_ratio %9.2f
format estimated_workers industry_workers %15.0fc
order month growth_rank industry dimension demographic_group industry_share_pct ///
    population_share_pct population_gap_pp population_rep_ratio workforce_benchmark ///
    workforce_share_pct workforce_gap_pp workforce_rep_ratio ///
    estimated_workers industry_workers sample_n largest_group
gsort month growth_rank dimension -industry_share_pct demographic_group
save "`composition'", replace
keep if month == "2026-10"
save "`comp_oct'"
keep if largest_group == 1
save "`leaders'"

* 6. Draw first and last observed values in each panel.
capture program drop lm_endpoint_chart
program define lm_endpoint_chart
    version 16.0
    syntax varlist(min=2 max=2 numeric), Panel(varname) Headline(string) ///
        Units(string) File(string) Period(string) [Foot(string) Cols(integer 3) ///
        Decimals(integer 1) Percent Height(real 8)]
    tokenize "`varlist'"
    local y "`1'"
    local x "`2'"
    preserve
        keep if !missing(`y',`x')
        assert _N > 0
        tempvar endpoint
        bysort `panel' (`x'): generate str16 `endpoint' = ///
            strtrim(string(`y',"%12.`decimals'f")) if _n==1 | _n==_N
        if "`percent'" != "" replace `endpoint' = `endpoint' + "%" if `endpoint' != ""
        quietly summarize `y', meanonly
        local pad = max((r(max)-r(min))*.14,.15)
        local ymin = r(min)-`pad'*.28
        local ymax = r(max)+`pad'
        quietly summarize `x', meanonly
        local xmin = r(min)-max((r(max)-r(min))*.075,.65)
        local xmax = r(max)+max((r(max)-r(min))*.075,.65)
        local axis 1 "Jan" 3 "Mar" 5 "May" 7 "Jul" 10 "Oct"
        if "`period'" == "annual" local axis 2001 2005 2010 2015 2020 2026 "2026*"
        if "`period'" == "ytd" local axis 2019 2021 2023 2026
        if "`period'" == "forecast" local axis 1 3 6 9 12
        twoway (connected `y' `x', sort lcolor(navy) lwidth(medthick) ///
                    mcolor(navy) msize(tiny)) ///
               (scatter `y' `x' if `endpoint' != "", msymbol(O) mcolor(navy) ///
                    msize(small) mlabel(`endpoint') mlabposition(12) ///
                    mlabcolor(navy) mlabsize(small)), ///
            by(`panel', cols(`cols') title("`headline'", size(medium)) ///
                note("`foot'", size(vsmall)) legend(off)) ///
            xlabel(`axis', labsize(vsmall)) ylabel(, labsize(small) format(%9.1f) angle(horizontal)) ///
            xscale(range(`xmin' `xmax')) yscale(range(`ymin' `ymax')) ///
            xtitle("") ytitle("`units'", size(small)) subtitle(, size(small)) ///
            graphregion(color(white) margin(5 5 4 5)) xsize(13) ysize(`height')
        graph export "`file'", width(2400) replace
    restore
end

use "`lfp'", clear
generate byte chart_month = real(substr(month,6,2))
foreach group in age_group sex race race_sex {
    preserve
        keep if breakdown == "`group'"
        generate str60 panel = race
        if "`group'" == "age_group" replace panel = age_group
        if "`group'" == "sex" replace panel = sex
        if "`group'" == "race_sex" replace panel = race + " / " + sex
        replace panel = subinstr(panel,"Native Hawaiian or Pacific Islander alone","NHPI alone",.)
        replace panel = subinstr(panel,"American Indian or Alaska Native alone","AIAN alone",.)
        local group_title "race"
        local cols 3
        local tall 8
        if "`group'" == "age_group" local group_title "age"
        if "`group'" == "sex" {
            local group_title "sex"
            local cols 2
            local tall 6
        }
        if "`group'" == "race_sex" {
            local group_title "race and sex"
            local tall 11
        }
        foreach measure in participation unemployment {
            local metric "Labor force participation"
            if "`measure'" == "unemployment" local metric "Unemployment"
            lm_endpoint_chart `measure'_pct chart_month, panel(panel) ///
                headline("`metric' by `group_title'") units("Percent") ///
                file("`charts'/`measure'_by_`group'.png") period(monthly) percent ///
                cols(`cols') height(`tall') ///
                foot("Weighted CPS, Jan–Oct 2026. Not seasonally adjusted. NHPI = Native Hawaiian/Pacific Islander; AIAN = American Indian/Alaska Native.")
        }
    restore
}

use "`top_trend'", clear
generate byte chart_month = real(substr(month,6,2))
generate str60 industry_panel = string(growth_rank) + ". " + industry
lm_endpoint_chart change_since_dec_thousands chart_month, panel(industry_panel) ///
    headline("Top five industries by net jobs added") units("Jobs since December 2025 (thousands)") ///
    file("`charts'/top5_payroll_growth.png") period(monthly) height(7) ///
    foot("BLS CES, seasonally adjusted. January shows the change from December 2025.")

* Rank-aligned payroll and CPS sex composition. CPS reflects the stock of
* workers in October, and cannot attribute the newly added jobs by sex.
use "`comp_oct'", clear
keep if dimension == "sex" & inlist(demographic_group,"Men","Women")
keep growth_rank industry demographic_group industry_share_pct population_share_pct ///
    population_rep_ratio workforce_share_pct workforce_rep_ratio sample_n
isid growth_rank demographic_group
merge m:1 growth_rank industry using "`growth'", ///
    keep(match) keepusing(net_jobs_added_thousands) nogen
assert _N == 10
bysort growth_rank: assert _N == 2
generate double net_jobs_added = round(1000 * net_jobs_added_thousands)
order growth_rank industry net_jobs_added demographic_group industry_share_pct ///
    population_share_pct population_rep_ratio workforce_share_pct workforce_rep_ratio sample_n
format population_rep_ratio workforce_rep_ratio %9.2f
format net_jobs_added %15.0fc
save "`top5sex'"

* Short display labels and the same rank positions in all three panels.
generate str45 chart_industry = industry
replace chart_industry = "Professional & business services" if industry == "Professional and business services"
replace chart_industry = "Transportation & warehousing" if industry == "Transportation and warehousing"
replace chart_industry = "Private education" if industry == "Private educational services"
local ranks_axis ""
forvalues j = 1/5 {
    quietly levelsof chart_industry if growth_rank == `j', local(lbl) clean
    local ranks_axis `"`ranks_axis' `j' "`lbl'""'
}
generate double bar_y = growth_rank + cond(demographic_group=="Men",-.17,.17)
generate str18 jobs_label = strtrim(string(net_jobs_added,"%12.0fc"))
generate str12 share_label = strtrim(string(industry_share_pct,"%6.1f")) + "%"
generate str12 ratio_label = strtrim(string(population_rep_ratio,"%6.2f")) + "x"
quietly summarize net_jobs_added_thousands, meanonly
local xmax_jobs = max(r(max)*1.25,1)
quietly summarize population_rep_ratio, meanonly
local xmax_ratio = max(r(max)*1.23,1.25)

twoway (bar net_jobs_added_thousands growth_rank if demographic_group=="Men", ///
            horizontal barwidth(.55) color(navy)) ///
       (scatter growth_rank net_jobs_added_thousands if demographic_group=="Men", ///
            msymbol(none) mlabel(jobs_label) mlabposition(3) mlabsize(small) mlabcolor(navy)), ///
    yscale(reverse range(.45 5.55)) ylabel(`ranks_axis', angle(horizontal) labsize(small) noticks nogrid) ///
    xscale(range(0 `xmax_jobs')) xlabel(, labsize(small)) ///
    title("Net payroll jobs added", size(medsmall)) xtitle("Jobs (thousands)", size(small)) ///
    ytitle("") legend(off) graphregion(color(white) margin(4 4 4 4)) name(lm_growth_bar, replace) nodraw

twoway (bar industry_share_pct bar_y if demographic_group=="Men", horizontal barwidth(.28) color(navy)) ///
       (bar industry_share_pct bar_y if demographic_group=="Women", horizontal barwidth(.28) color(teal)) ///
       (scatter bar_y industry_share_pct, msymbol(none) mlabel(share_label) mlabposition(3) mlabsize(small)), ///
    yscale(reverse range(.45 5.55)) ylabel(none) ///
    xscale(range(0 119)) xlabel(0 25 50 75 100, labsize(small)) ///
    title("Share of industry workforce", size(medsmall)) xtitle("Percent", size(small)) ///
    ytitle("") legend(off) graphregion(color(white) margin(4 4 4 4)) name(lm_share_bar, replace) nodraw

twoway (bar population_rep_ratio bar_y if demographic_group=="Men", horizontal barwidth(.28) color(navy)) ///
       (bar population_rep_ratio bar_y if demographic_group=="Women", horizontal barwidth(.28) color(teal)) ///
       (scatter bar_y population_rep_ratio, msymbol(none) mlabel(ratio_label) mlabposition(3) mlabsize(small)), ///
    yscale(reverse range(.45 5.55)) ylabel(none) ///
    xscale(range(0 `xmax_ratio')) xlabel(, labsize(small) format(%4.1f)) xline(1,lpattern(dash) lcolor(gs8)) ///
    title("Representation relative to population", size(medsmall)) xtitle("Ratio (1.00 = proportional)", size(small)) ///
    ytitle("") legend(off) graphregion(color(white) margin(4 4 4 4)) name(lm_ratio_bar, replace) nodraw

* A separate color key keeps the three plotting areas aligned.
graph combine lm_growth_bar lm_share_bar lm_ratio_bar, cols(3) ///
    graphregion(color(white) margin(zero)) fysize(89) ///
    name(lm_sex_panels, replace) nodraw

twoway (scatteri .5 44 "Men", msymbol(S) mcolor(navy) msize(medlarge) ///
            mlabposition(3) mlabcolor(black) mlabsize(medium)) ///
       (scatteri .5 53 "Women", msymbol(S) mcolor(teal) msize(medlarge) ///
            mlabposition(3) mlabcolor(black) mlabsize(medium)), ///
    xscale(off range(0 100)) yscale(off range(0 1)) legend(off) ///
    plotregion(lcolor(none) margin(zero)) graphregion(color(white) margin(zero)) ///
    fysize(11) name(lm_sex_key, replace) nodraw

graph combine lm_sex_panels lm_sex_key, cols(1) imargin(zero) ///
    title("Top five industries by jobs added in 2026", size(medium)) ///
    subtitle("Payroll change from December 2025 to October 2026", size(small)) ///
    note("Ratios compare industry shares with civilian population shares, age 16+." ///
         "Sources: BLS CES payrolls and weighted October CPS. Workforce shares describe current workers.", size(vsmall)) ///
    graphregion(color(white) margin(4 4 4 4)) xsize(16) ysize(6)
graph export "`charts'/top5_jobs_and_workforce_by_sex.png", width(3000) replace
graph drop lm_growth_bar lm_share_bar lm_ratio_bar lm_sex_panels lm_sex_key

* 7. Export one workbook and place the interpretation notes on its first tab.
clear
input str28 topic str240 detail
"Period" "January to October 2026. October is the latest month in the supplied inputs."
"Participation" "Civilian adults age 16 and over. Weighted employed plus unemployed divided by the weighted civilian population in each cell."
"Age bands" "16-24, 25-54, and 55+. Participation for ages 55+ reflects retirement alongside other reasons for being outside the labor force."
"Other CPS measures" "Unemployment is the unemployed share of the labor force. Employment is the employed share of the civilian population. Change columns are percentage-point differences from January."
"Representation" "Industry share divided by the same group's benchmark share. Values above 1 indicate overrepresentation. A gap is industry share minus benchmark share, in percentage points."
"Benchmarks" "Civilian population age 16+ and the comparable workforce in the same month. The latter uses all mapped CPS private-sector workers or all government workers for government."
"Zero cells" "A zero count means the group had no observed workers in that industry-month sample. A ratio is blank if the benchmark share is zero. Use sample counts to assess sparse cells."
"CPS estimates" "Monthly public-use estimates are not seasonally adjusted. sample_n is the number of survey records. Compare small groups cautiously. No margins of error are calculated."
"Race and ethnicity" "Race uses mutually exclusive reported race groups. Hispanic ethnicity is a separate dimension and may overlap any race."
"Industry ranking" "Ranked by October 2026 minus December 2025 seasonally adjusted CES payroll employment, in thousands of jobs. Sixteen non-overlapping industry categories are compared."
"Ranking ties" "A tie in net jobs added is broken by the BLS industry order used in the do-file."
"Workforce demographics" "Weighted CPS workers in their primary job, grouped by the CES industry mapping. Industry shares are calculated separately for each demographic dimension."
"Largest group" "The largest reported group is shown for each dimension and industry. Ties are retained. Unknown groups contribute to the denominator."
"Interpretation" "CES counts payroll jobs. CPS counts employed people. Demographic shares describe workers already in an industry and do not identify who filled newly added jobs."
"Input files" "Census January through October monthly CPS CSVs, Census industry codes CSV, and BLS ce.series and ce.data.0.AllCESSeries."
end
export excel using "`book'", sheet("Notes") firstrow(variables) replace

local datasets "lfp_oct lfp growth top_trend top5sex leaders comp_oct composition"
local sheets "Participation_Oct Participation_Monthly Industry_Ranking Top5_Payroll_Trend Top5_Jobs_and_Sex Top5_Largest_Groups Top5_Demographics_Oct Top5_Demographics_Monthly"
local tab = 0
foreach dataset of local datasets {
    local ++tab
    local sheet : word `tab' of `sheets'
    use "``dataset''", clear
    export excel using "`book'", sheet("`sheet'", replace) firstrow(variables)
}

display as result "Workbook saved: `book'"
display as result "Charts saved: `charts'"

* 8. National macro forecasts. Uses only local downloads.
* Change these assumptions to test the AI hiring channel.
* Impact is the assumed JOLTS hires-rate shift (pp) per 10 pp of extra adoption.
local ai_extra_at_12m 10
local ai_weak_hires_per_10pp -.25
local ai_strong_hires_per_10pp .25
local cutoff = tm(2026m10)
local fcbook "`results'/Labor_Market_Forecasts_2026.xlsx"
local fred "INDPRO FEDFUNDS CPIAUCSL JTSJOR JTSHIR JTSLDR GDPC1"
foreach filename in ln.data.1.AllData np2023_d1_mid.csv National.xlsx Sector.xlsx {
    confirm file "`data'/`filename'"
}
foreach code of local fred {
    confirm file "`data'/`code'.csv"
}

tempfile fredmonth fredgdp history monthlyout monthlyeval quarterlyout quarterlyeval ///
    btosdates btnat btsect forecastwide ageweights

* FRED downloads have a date in the first column and the named series second.
local first = 1
foreach code of local fred {
    import delimited using "`data'/`code'.csv", varnames(1) stringcols(1) ///
        case(lower) asdouble clear
    unab allcols : _all
    local datecol : word 1 of `allcols'
    local valuecol = lower("`code'")
    confirm variable `valuecol'
    capture confirm numeric variable `valuecol'
    if _rc destring `valuecol', replace
    generate int tm = mofd(daily(`datecol',"YMD"))
    assert !missing(tm)
    keep tm `valuecol'
    keep if inrange(tm,tm(1999m1),`cutoff')
    isid tm
    if "`code'" == "GDPC1" {
        generate int tq = qofd(dofm(tm))
        drop tm
        isid tq
        save "`fredgdp'"
    }
    else {
        if !`first' merge 1:1 tm using "`fredmonth'", nogen
        save "`fredmonth'", replace
        local first = 0
    }
}

* Published, seasonally adjusted outcomes and unadjusted CPS age populations.
* IDs can be checked against the downloaded ln.series metadata file.
tempfile ln_copy
local ln_csv "`ln_copy'.csv"
display as text "Reading BLS household survey history for the forecasts."
copy "`data'/ln.data.1.AllData" "`ln_csv'"
capture noisily import delimited using "`ln_csv'", delimiters(tab) varnames(nonames) ///
    rowrange(2) colrange(1:4) stringcols(1 3 4) clear
local ln_rc = _rc
capture erase "`ln_csv'"
if `ln_rc' exit `ln_rc'
rename (v1 v2 v3 v4) (series_id year period value)
keep if year >= 1999 & year <= 2026
replace series_id = strtrim(series_id)
generate str12 outcome = ""
replace outcome = "u3" if series_id == "LNS14000000"
replace outcome = "lfpr" if series_id == "LNS11300000"
replace outcome = "lfpr_youth" if series_id == "LNS11324887"
replace outcome = "lfpr_prime" if series_id == "LNS11300060"
replace outcome = "lfpr_older" if series_id == "LNS11324230"
replace outcome = "pop_youth" if series_id == "LNU00024887"
replace outcome = "pop_prime" if series_id == "LNU00000060"
replace outcome = "pop_older" if series_id == "LNU00024230"
replace outcome = "epop" if series_id == "LNS12300000"
replace outcome = "u6" if series_id == "LNS13327709"
replace outcome = "u3_youth" if series_id == "LNS14024887"
replace outcome = "u3_prime" if series_id == "LNS14000060"
replace outcome = "u3_older" if series_id == "LNS14024230"
replace outcome = "lfpr_men" if series_id == "LNS11300001"
replace outcome = "u3_men" if series_id == "LNS14000001"
replace outcome = "lfpr_women" if series_id == "LNS11300002"
replace outcome = "u3_women" if series_id == "LNS14000002"
replace outcome = "lfpr_white" if series_id == "LNS11300003"
replace outcome = "u3_white" if series_id == "LNS14000003"
replace outcome = "lfpr_black" if series_id == "LNS11300006"
replace outcome = "u3_black" if series_id == "LNS14000006"
replace outcome = "lfpr_hisp" if series_id == "LNS11300009"
replace outcome = "u3_hisp" if series_id == "LNS14000009"
replace outcome = "lfpr_asian" if series_id == "LNS11332183"
replace outcome = "u3_asian" if series_id == "LNS14032183"
keep if outcome != ""
generate byte month_number = real(substr(strtrim(period),2,2))
keep if inrange(month_number,1,12)
generate int tm = ym(year,month_number)
keep if tm <= `cutoff'
* Explicit missing markers may be present in the bulk data.
replace value = "" if inlist(strtrim(value),"-","—",".")
destring value, replace
keep tm outcome value
isid tm outcome
reshape wide value, i(tm) j(outcome) string
rename value* *
save "`cpshist'"
merge 1:1 tm using "`fredmonth'", nogen
sort tm
format tm %tm
tsset tm, monthly
tsfill
generate double x_activity = 100 * (ln(L2.indpro) - ln(L5.indpro))
generate double x_realrate = L2.fedfunds - 100 * (L2.cpiaucsl/L14.cpiaucsl - 1)
generate double x_openings = L2.jtsjor
generate double x_hires = L2.jtshir
generate double x_layoffs = L2.jtsldr
save "`history'"

* Fit a separate direct regression of the change over each forecast horizon.
* At each historical origin only training targets already observed are used.
* Predictor lags reflect usual publication delays. The inputs are revised
* downloads, so this is a pseudo-real-time evaluation.
capture program drop lm_direct_forecast
program define lm_direct_forecast
    version 16.0
    syntax, Time(varlist min=1 max=1 numeric) Outcomes(string) Horizons(numlist integer >0) ///
        Controls(varlist numeric) Origin(integer) Backstart(integer) ///
        Mintrain(integer) Moment(integer) Output(string) Evaluation(string) ///
        [Hirevar(varlist min=1 max=1 numeric)]

    tempname pf pe
    postfile `pf' str16 outcome int horizon int origin int target_period ///
        double actual_at_origin baseline flat low high hires_slope ///
        rmse_model rmse_flat mae_model mae_flat int n_backtest using "`output'", replace
    postfile `pe' str16 outcome int horizon int origin int target_period ///
        double actual model flat using "`evaluation'", replace
    tempvar momentum change xb backlog ae nf sq sqflat err
    local horizonlist "`horizons'"
    foreach y of local outcomes {
        quietly generate double `momentum' = `y' - L`moment'.`y'
        foreach h of local horizonlist {
            quietly generate double `change' = F`h'.`y' - `y'
            quietly generate double `backlog' = .
            quietly generate double `nf' = .
            local last_origin = `origin' - `h'
            forvalues t = `backstart'/`last_origin' {
                quietly count if `time' == `t' & !missing(`change',`momentum')
                if r(N) == 0 continue
                capture quietly regress `change' `y' `momentum' `controls' ///
                    if `time' + `h' <= `t'
                if _rc continue
                if e(N) < `mintrain' continue
                quietly predict double `xb' if `time' == `t', xb
                quietly summarize `change' if `time' == `t' & !missing(`xb'), meanonly
                if r(N) > 0 {
                    local realized_change = r(mean)
                    quietly summarize `y' if `time' == `t', meanonly
                    local anchor = r(mean)
                    quietly summarize `xb' if `time' == `t', meanonly
                    local fitted = max(0,min(100,`anchor' + r(mean)))
                    local observed = `anchor' + `realized_change'
                    quietly replace `backlog' = `observed' - `fitted' if `time' == `t'
                    quietly replace `nf' = `realized_change' if `time' == `t'
                    post `pe' ("`y'") (`h') (`t') (`t'+`h') ///
                        (`observed') (`fitted') (`anchor')
                }
                drop `xb'
            }
            quietly generate double `ae' = abs(`backlog')
            quietly count if !missing(`ae')
            local n = r(N)
            if `n' < 10 {
                display as error "Insufficient backtest history for `y', horizon `h'. Check full-history CSV downloads."
                exit 459
            }
            quietly _pctile `ae', p(80)
            local radius = r(r1)
            quietly summarize `ae', meanonly
            local mae = r(mean)
            quietly generate double `err' = abs(`nf')
            quietly summarize `err', meanonly
            local naive_mae = r(mean)
            quietly generate double `sq' = `backlog'^2
            quietly generate double `sqflat' = `nf'^2
            quietly summarize `sq', meanonly
            local rmse = sqrt(r(mean))
            quietly summarize `sqflat', meanonly
            local naive_rmse = sqrt(r(mean))

            quietly regress `change' `y' `momentum' `controls' if `time' + `h' <= `origin'
            assert e(N) >= `mintrain'
            local hire_slope = .
            if "`hirevar'" != "" local hire_slope = _b[`hirevar']
            quietly predict double `xb' if `time' == `origin', xb
            quietly summarize `xb', meanonly
            local projected = r(mean)
            assert r(N) == 1
            quietly summarize `y' if `time' == `origin', meanonly
            local anchor = r(mean)
            assert r(N) == 1
            local baseline = max(0,min(100,`anchor'+`projected'))
            post `pf' ("`y'") (`h') (`origin') (`origin'+`h') ///
                (`anchor') (`baseline') (`anchor') ///
                (max(0,`baseline'-`radius')) (min(100,`baseline'+`radius')) ///
                (`hire_slope') (`rmse') (`naive_rmse') (`mae') (`naive_mae') (`n')
            drop `change' `xb' `backlog' `ae' `nf' `sq' `sqflat' `err'
        }
        drop `momentum'
    }
    postclose `pf'
    postclose `pe'
end

* Latest month with all required predictors, outcomes and outcome lags.
generate byte ready = !missing(u3,lfpr,lfpr_youth,lfpr_prime,lfpr_older, ///
    L3.u3,L3.lfpr,L3.lfpr_youth,L3.lfpr_prime,L3.lfpr_older, ///
    x_activity,x_realrate,x_openings,x_hires,x_layoffs,pop_youth,pop_prime,pop_older)
quietly summarize tm if ready, meanonly
local morigin = r(max)
assert r(N) > 0
foreach g in youth prime older {
    quietly summarize pop_`g' if tm == `morigin', meanonly
    local anchor_`g' = r(mean)
}
display as text "Fitting monthly macro models and rolling backtests."
lm_direct_forecast, time(tm) outcomes("u3 lfpr lfpr_youth lfpr_prime lfpr_older") ///
    horizons(1/12) controls(x_activity x_realrate x_openings x_hires x_layoffs) ///
    origin(`morigin') backstart(`=tm(2015m1)') mintrain(96) moment(3) ///
    output("`monthlyout'") evaluation("`monthlyeval'") hirevar(x_hires)

* Quarterly comparison: GDP growth available with a one-quarter lag.
use "`history'", clear
generate int tq = qofd(dofm(tm))
collapse (mean) u3 lfpr fedfunds cpiaucsl jtshir ///
    (count) u_n=u3 p_n=lfpr, by(tq)
replace u3 = . if u_n != 3
replace lfpr = . if p_n != 3
merge 1:1 tq using "`fredgdp'", nogen
format tq %tq
tsset tq, quarterly
tsfill
generate double x_gdp = 100 * (ln(L.gdpc1)-ln(L2.gdpc1))
generate double x_realrate = L.fedfunds - 100 * (L.cpiaucsl/L5.cpiaucsl - 1)
generate double x_hires = L.jtshir
quietly summarize tq if !missing(u3,lfpr,L.u3,L.lfpr,x_gdp,x_realrate,x_hires), meanonly
local qorigin = r(max)
assert r(N) > 0
lm_direct_forecast, time(tq) outcomes("u3 lfpr") horizons(1 2 4) ///
    controls(x_gdp x_realrate x_hires) origin(`qorigin') ///
    backstart(`=tq(2015q1)') mintrain(36) moment(1) ///
    output("`quarterlyout'") evaluation("`quarterlyeval'")

* Census main-series age counts adjust the future mix. Interpolate between
* July projections, then anchor projected growth to the latest CPS counts.
import delimited using "`data'/np2023_d1_mid.csv", varnames(1) case(lower) asdouble clear
keep if sex == 0 & race == 0 & origin == 0
isid year
local youthcols ""
local primecols ""
local oldercols ""
forvalues a = 16/100 {
    if `a' <= 24 local youthcols "`youthcols' pop_`a'"
    else if `a' <= 54 local primecols "`primecols' pop_`a'"
    else local oldercols "`oldercols' pop_`a'"
}
foreach g in youth prime older {
    egen double census_`g' = rowtotal(``g'cols'), missing
}
generate int tm = ym(year,7)
keep tm census_youth census_prime census_older
tsset tm, monthly
tsfill
foreach g in youth prime older {
    ipolate census_`g' tm, generate(interpolated)
    quietly summarize interpolated if tm == `morigin', meanonly
    local at_origin = r(mean)
    assert r(N) == 1 & `at_origin' > 0
    generate double weight_`g' = `anchor_`g'' * interpolated / `at_origin'
    drop interpolated
}
keep if inrange(tm,`morigin'+1,`morigin'+12)
assert _N == 12
generate double age_total = weight_youth + weight_prime + weight_older
foreach g in youth prime older {
    replace weight_`g' = weight_`g' / age_total
    assert inrange(weight_`g',0,1)
}
keep tm weight_youth weight_prime weight_older
rename tm target_period
save "`ageweights'"

* Read BTOS field dates and Question 7 ("Yes", current business AI/SI use).
* Use survey publication date to enforce the analysis information cutoff.
import excel using "`data'/National.xlsx", sheet("Collection and Reference Dates") ///
    allstring clear
generate long wave = real(strtrim(D))
keep if !missing(wave)
generate double collection_start = daily(E,"MDY")
replace collection_start = daily(E,"YMD") if missing(collection_start)
replace collection_start = daily(E,"DMY") if missing(collection_start)
replace collection_start = real(E)-21916 if missing(collection_start) & inrange(real(E),40000,60000)
generate double publication_date = daily(I,"MDY")
replace publication_date = daily(I,"YMD") if missing(publication_date)
replace publication_date = daily(I,"DMY") if missing(publication_date)
replace publication_date = real(I)-21916 if missing(publication_date) & inrange(real(I),40000,60000)
* Three shutdown waves in October-November 2025 had no publication date.
* Keep their metadata to match the workbook, then exclude unpublished waves.
assert !missing(collection_start)
assert strtrim(I) == "" if missing(publication_date)
format collection_start publication_date %tdCCYY-NN-DD
keep wave collection_start publication_date
isid wave
save "`btosdates'"

foreach scope in National Sector {
    import excel using "`data'/`scope'.xlsx", sheet("Response Estimates") allstring clear
    local q A
    local ans D
    if "`scope'" == "Sector" {
        local q B
        local ans E
    }
    unab columns : _all
    local wavecols ""
    foreach v of local columns {
        local header = strtrim(`v'[1])
        if regexm("`header'","^20[0-9][0-9][0-9][0-9]$") {
            rename `v' ai_`header'
            local wavecols "`wavecols' ai_`header'"
        }
    }
    if "`wavecols'" == "" {
        display as error "No BTOS survey-wave headers found in `scope'.xlsx."
        exit 459
    }
    keep if real(`q') == 7 & lower(strtrim(`ans')) == "yes"
    assert _N > 0
    generate str16 sector = "National"
    if "`scope'" == "Sector" replace sector = strtrim(A)
    keep sector `wavecols'
    isid sector
    reshape long ai_, i(sector) j(wave)
    generate double adoption_pct = real(subinstr(strtrim(ai_),"%","",.))
    drop ai_
    merge m:1 wave using "`btosdates'", assert(match using) keep(match) nogen
    keep if !missing(publication_date) & collection_start >= td(17nov2025) ///
        & publication_date <= td(15nov2026)
    assert _N > 0
    assert inrange(adoption_pct,0,100) if !missing(adoption_pct)
    order sector wave collection_start publication_date adoption_pct
    sort sector publication_date
    if "`scope'" == "National" {
        quietly summarize publication_date if !missing(adoption_pct), meanonly
        local ai_date = r(max)
        quietly summarize adoption_pct if publication_date == `ai_date', meanonly
        local ai_base = r(mean)
        assert r(N) == 1
        save "`btnat'"
    }
    else save "`btsect'"
}

* Sensitivities evaluate each direct forecast at a shifted hiring input.
* The shift is a hiring-rate equivalent, not an estimated effect of adoption.
use "`monthlyout'", clear
generate double observed_btos_pct = `ai_base'
generate int btos_publication_date = `ai_date'
format btos_publication_date %tdCCYY-NN-DD
generate double extra_adoption_pp = min(100-observed_btos_pct,`ai_extra_at_12m'*horizon/12)
generate double higher_adoption_pct = observed_btos_pct + extra_adoption_pp
generate double weaker_hiring_pp = extra_adoption_pp/10 * `ai_weak_hires_per_10pp'
generate double stronger_hiring_pp = extra_adoption_pp/10 * `ai_strong_hires_per_10pp'
generate double ai_weaker_hiring = max(0,min(100,baseline + hires_slope*weaker_hiring_pp))
generate double ai_stronger_hiring = max(0,min(100,baseline + hires_slope*stronger_hiring_pp))
assert !missing(baseline,ai_weaker_hiring,ai_stronger_hiring)
merge m:1 target_period using "`ageweights'", assert(match) nogen
format origin target_period %tmCCYY-NN
format baseline flat low high actual_at_origin ai_weaker_hiring ai_stronger_hiring %9.2f
generate byte macro_beats_flat_mae = mae_model < mae_flat
sort outcome horizon
save "`monthlyout'", replace

* Weighted participation and consistent employment-to-population scenarios.
keep outcome horizon target_period baseline ai_weaker_hiring ai_stronger_hiring weight_*
reshape wide baseline ai_weaker_hiring ai_stronger_hiring, i(horizon target_period) j(outcome) string
foreach case in baseline ai_weaker_hiring ai_stronger_hiring {
    generate double `case'_age_lfpr = `case'lfpr_youth*weight_youth + ///
        `case'lfpr_prime*weight_prime + `case'lfpr_older*weight_older
    generate double `case'_epop = `case'_age_lfpr * (1-`case'u3/100)
}
keep horizon target_period weight_* baselineu3 baseline_age_lfpr baseline_epop ///
    ai_weaker_hiringu3 ai_weaker_hiring_age_lfpr ai_weaker_hiring_epop ///
    ai_stronger_hiringu3 ai_stronger_hiring_age_lfpr ai_stronger_hiring_epop
assert _N == 12
format target_period %tmCCYY-NN
save "`forecastwide'"

* Deliver forecast model data, diagnostics, assumptions, and sources.
clear
input str32 topic str244 detail
"Monthly model" "Separate direct change regressions at 1 through 12 months for national U-3, overall LFPR, and LFPR ages 16-24, 25-54 and 55+. Rate levels and three-month momentum capture persistence."
"Monthly economic controls" "Two-month-lagged industrial production growth over three months, real funds rate proxy, and JOLTS openings, hires and layoffs rates. The real rate subtracts trailing 12-month CPI inflation."
"Quarterly comparison" "Direct U-3 and overall LFPR forecasts at 1, 2 and 4 quarters. Uses lagged quarterly real GDP log growth, real policy-rate proxy and hires. Outcomes are averages of three available months."
"Backtest" "Expanding windows from 2015 onward. Only realized targets through each origin enter training. Current revised data and approximate release lags make this a pseudo-real-time backtest."
"Forecast error bands" "Baseline plus/minus the 80th percentile of absolute rolling forecast errors, bounded at 0 and 100. Empirical bands have no guaranteed future coverage and exclude AI scenario uncertainty."
"Benchmark" "Flat forecast carries the latest rate forward. Models are reported even if they lose to the benchmark. Smaller MAE and RMSE are better."
"AI data" "Census BTOS Question 7, Yes response, business AI/SI use. National and sector series are restricted to the broader question period beginning November 17, 2025."
"AI scenarios" "Both higher-adoption paths ramp up extra adoption from the latest observed BTOS level. They differ in the assumed shift to the JOLTS hires-rate input. Other model inputs are held fixed."
"AI interpretation" "Hiring shifts are editable stress assumptions. Historical hiring coefficients translate them into outcomes. The BTOS data do not identify a causal AI coefficient."
"Age adjustment" "Monthly population mix uses Census July-to-July projections interpolated by age band and anchored to CPS civilian population counts at the monthly forecast origin."
"Derived employment" "Age-weighted national LFPR times one minus U-3 divided by 100. The separate direct national LFPR forecast has its own backtest; the age-weighted path is a demographic cross-check."
"Sources: outcomes" "BLS CPS series in ln.data.1.AllData. Series identifiers and local input names are in the do-file. Current Population Survey: https://www.bls.gov/cps/"
"Sources: macro" "FRED downloads from Federal Reserve, BLS and BEA. INDPRO, FEDFUNDS, CPIAUCSL, JTSJOR, JTSHIR, JTSLDR and GDPC1. https://fred.stlouisfed.org/"
"Sources: AI and population" "Census BTOS National.xlsx and Sector.xlsx; Census 2023 National Population Projections main series, np2023_d1_mid.csv."
"Economic framework" "Okun's law motivates growth; Mortensen and Pissarides (1994) motivate vacancy, hiring and separation measures; Acemoglu and Restrepo (2019) motivate AI displacement and job creation scenarios."
end
export excel using "`fcbook'", sheet("Methods") firstrow(variables) replace

local forecastdata "forecastwide monthlyout monthlyeval quarterlyout quarterlyeval btnat btsect history"
local forecastsheets "Scenario_Comparison Monthly_Models Monthly_Backtest Quarterly_GDP_Model Quarterly_Backtest BTOS_National BTOS_Sectors Model_History"
local ft = 0
foreach d of local forecastdata {
    local ++ft
    local sheet : word `ft' of `forecastsheets'
    use "``d''", clear
    if inlist("`d'","quarterlyout","quarterlyeval") {
        format origin target_period %tq
    }
    if "`d'" == "monthlyeval" format origin target_period %tmCCYY-NN
    export excel using "`fcbook'", sheet("`sheet'", replace) firstrow(variables)
}

* Charts show all 12 direct monthly forecast horizons, in percent.
use "`forecastwide'", clear
foreach metric in u3 age_lfpr epop {
    local base baseline_`metric'
    local weak ai_weaker_hiring_`metric'
    local strong ai_stronger_hiring_`metric'
    local title "Age-weighted labor force participation"
    if "`metric'" == "u3" {
        local base baselineu3
        local weak ai_weaker_hiringu3
        local strong ai_stronger_hiringu3
        local title "U.S. unemployment"
    }
    if "`metric'" == "epop" local title "Employment-to-population ratio"
    preserve
        keep horizon `base' `weak' `strong'
        rename (`base' `weak' `strong') (plot_value1 plot_value2 plot_value3)
        reshape long plot_value, i(horizon) j(path)
        generate str28 forecast_panel = "1. Macro baseline"
        replace forecast_panel = "2. Higher AI / weaker hires" if path==2
        replace forecast_panel = "3. Higher AI / stronger hires" if path==3
        lm_endpoint_chart plot_value horizon, panel(forecast_panel) ///
            headline("`title' forecast") units("Percent") ///
            file("`charts'/forecast_`metric'.png") period(forecast) percent ///
            decimals(2) height(6) foot("Forecast months 1–12. All scenarios share the same scale.")
    restore
}
capture program drop lm_direct_forecast
display as result "Forecast workbook saved: `fcbook'"

* 9. Historical trends using the already downloaded CPS and CES bulk files.
* Annual series include 2026 year to date; matched-month views are separate.
local annualbook "`results'/Labor_Market_Annual_Trends_2001_2026.xlsx"
use "`cpshist'", clear
foreach v of varlist u3* u6 lfpr* epop {
    rename `v' history_`v'
}
keep tm history_*
reshape long history_, i(tm) j(series) string
rename history_ rate_pct
drop if missing(rate_pct)
generate int year = year(dofm(tm))
generate byte month_no = month(dofm(tm))
keep if inrange(year,2001,2026)

generate str25 measure = "Unemployment (U-3)"
replace measure = "Labor force participation" if strpos(series,"lfpr")==1
replace measure = "Underutilization (U-6)" if series=="u6"
replace measure = "Employment-to-population" if series=="epop"
generate str26 group = "All ages 16+"
replace group = "16-24" if strpos(series,"_youth")
replace group = "25-54" if strpos(series,"_prime")
replace group = "55+" if strpos(series,"_older")
replace group = "Men" if strpos(series,"_men")
replace group = "Women" if strpos(series,"_women")
replace group = "White" if strpos(series,"_white")
replace group = "Black" if strpos(series,"_black")
replace group = "Asian" if strpos(series,"_asian")
replace group = "Hispanic or Latino" if strpos(series,"_hisp")
generate str8 breakdown = "National"
replace breakdown = "Age" if inlist(group,"16-24","25-54","55+")
replace breakdown = "Sex" if inlist(group,"Men","Women")
replace breakdown = "Race" if inlist(group,"White","Black","Asian","Hispanic or Latino")

preserve
    collapse (mean) rate_pct (count) months_observed=rate_pct, ///
        by(year series measure breakdown group)
    replace rate_pct = . if (year<=2024 & months_observed!=12) | (year==2025 & months_observed!=11)
    generate str32 coverage = "12 months" if months_observed==12
    replace coverage = "11 months (October unavailable)" if year==2025 & months_observed==11
    replace coverage = "2026 year to date" if year==2026
    replace coverage = "Incomplete; average suppressed" if missing(rate_pct)
    bysort series (year): generate double change_since_2001_pp = rate_pct - rate_pct[1] if year[1]==2001
    format rate_pct change_since_2001_pp %9.2f
    order year measure breakdown group rate_pct change_since_2001_pp months_observed coverage series
    save "`annualcps'"
restore

expand 2, generate(second_window)
generate byte window_end = 9 + second_window
keep if month_no <= window_end
collapse (mean) rate_pct (count) months_observed=rate_pct, ///
    by(year window_end series measure breakdown group)
generate str12 period = cond(window_end==9,"Jan–Sep","Jan–Oct")
* Keep incomplete windows visible in the coverage column but blank their
* averages so they cannot be confused with a like-for-like comparison.
replace rate_pct = . if months_observed != window_end
format rate_pct %9.2f
order year period measure breakdown group rate_pct months_observed
save "`ytdcps'"

use "`ceshist'", clear
preserve
    collapse (mean) average_jobs_thousands=jobs_thousands (count) months_observed=jobs_thousands, ///
        by(year sector_id industry series_id)
    replace average_jobs_thousands = . if year<=2025 & months_observed!=12
    generate str32 coverage = "12 months" if months_observed==12
    replace coverage = "2026 year to date" if year==2026
    replace coverage = "Incomplete; average suppressed" if missing(average_jobs_thousands)
    bysort sector_id (year): generate double jobs_change_thousands = ///
        average_jobs_thousands-average_jobs_thousands[1] if year[1]==2001
    by sector_id: generate double jobs_change_pct = ///
        100*(average_jobs_thousands/average_jobs_thousands[1]-1) if year[1]==2001
    format average_jobs_thousands jobs_change_thousands jobs_change_pct %12.2f
    order year industry average_jobs_thousands jobs_change_thousands jobs_change_pct months_observed coverage
    save "`annualces'"
restore

expand 2, generate(second_window)
generate byte window_end = 9 + second_window
keep if month_no <= window_end
collapse (mean) average_jobs_thousands=jobs_thousands (count) months_observed=jobs_thousands, ///
    by(year window_end sector_id industry series_id)
replace average_jobs_thousands = . if months_observed != window_end
generate str12 period = cond(window_end==9,"Jan–Sep","Jan–Oct")
format average_jobs_thousands %12.2f
order year period industry average_jobs_thousands months_observed
save "`ytdces'"

clear
input str32 topic str244 detail
"Annual coverage" "2001–2024 CPS averages require 12 months. The 2025 CPS average uses 11 months because October was not collected. The 2026 endpoint averages available observations through October."
"Partial year" "2026 is reported as January–September and January–October. Compare the same window across years. A missing month blanks the matched-window average, including January–October 2025 CPS."
"Payrolls" "BLS CES seasonally adjusted payroll jobs, in thousands. 2001–2025 values average 12 levels. The 2026 endpoint averages January–October. Total nonfarm is shown separately from the industry ranking."
"Household groups" "Selected published national CPS series by age, sex, race and Hispanic ethnicity. Hispanic people can be of any race. Historical race-by-sex-by-age estimates require separate microdata."
"Chart endpoints" "Labels show the first and last observed values in every panel. Industry leaders are the six with the largest increase in average payrolls between 2001 and 2025."
"Sources" "BLS Current Population Survey (ln.data.1.AllData) and Current Employment Statistics (ce.data.0.AllCESSeries)."
end
export excel using "`annualbook'", sheet("Readme") firstrow(variables) replace
local histdata "annualcps ytdcps annualces ytdces"
local histsheets "Annual_Household Annual_Matched_Months_CPS Annual_Payroll Annual_Matched_Months_CES"
forvalues h = 1/4 {
    local ds : word `h' of `histdata'
    local sheet : word `h' of `histsheets'
    use "``ds''", clear
    sort year
    export excel using "`annualbook'", sheet("`sheet'", replace) firstrow(variables)
}

local annualnote "BLS CPS, seasonally adjusted. 2025 excludes October. *2026 averages available months through October."
use "`annualcps'", clear
preserve
    keep if inlist(series,"u3","u6")
    lm_endpoint_chart rate_pct year, panel(measure) ///
        headline("Unemployment and underutilization | 2001–2026") units("Percent") ///
        file("`charts'/annual_unemployment_and_u6.png") period(annual) percent ///
        cols(2) height(6) foot("`annualnote'")
restore
preserve
    keep if inlist(series,"lfpr","epop")
    lm_endpoint_chart rate_pct year, panel(measure) ///
        headline("Participation and employment | 2001–2026") units("Percent") ///
        file("`charts'/annual_participation_and_employment.png") period(annual) percent ///
        cols(2) height(6) foot("`annualnote'")
restore
foreach dimension in Age Sex Race {
    foreach metric in lfpr u3 {
        preserve
            keep if breakdown == "`dimension'" & strpos(series,"`metric'_")==1
            local title "Labor force participation"
            if "`metric'" == "u3" local title "Unemployment"
            local columns = cond("`dimension'"=="Age",3,2)
            local tall = cond("`dimension'"=="Race",8,6)
            local filegroup = lower("`dimension'")
            lm_endpoint_chart rate_pct year, panel(group) ///
                headline("`title' by `filegroup' | 2001–2026") units("Percent") ///
                file("`charts'/annual_`metric'_by_`filegroup'.png") period(annual) percent ///
                cols(`columns') height(`tall') foot("`annualnote'")
        restore
    }
}

use "`ytdcps'", clear
keep if inlist(series,"u3","u6") & window_end==9 & year>=2019
lm_endpoint_chart rate_pct year, panel(measure) ///
    headline("Unemployment and underutilization through 2026") units("Percent") ///
    file("`charts'/matched_months_labor_market.png") period(ytd) percent ///
    cols(2) height(6) foot("BLS CPS. Each point averages January–September of that year.")

use "`annualces'", clear
generate double payroll_millions = average_jobs_thousands/1000
preserve
    keep if sector_id==0
    lm_endpoint_chart payroll_millions year, panel(industry) ///
        headline("U.S. nonfarm payroll employment | 2001–2026") units("Jobs (millions)") ///
        file("`charts'/annual_total_payroll.png") period(annual) cols(1) height(6) ///
        decimals(1) foot("BLS CES, seasonally adjusted. *2026 averages January–October.")
restore
keep if sector_id>0
preserve
    keep if year==2025 & !missing(jobs_change_thousands)
    gsort -jobs_change_thousands sector_id
    assert _N >= 6
    keep in 1/6
    generate byte rank = _n
    keep sector_id rank
    tempfile leaders_annual
    save "`leaders_annual'"
restore
merge m:1 sector_id using "`leaders_annual'", keep(match) nogen
generate str55 industrypanel = string(rank) + ". " + industry
lm_endpoint_chart payroll_millions year, panel(industrypanel) ///
    headline("Industries adding the most jobs since 2001") units("Jobs (millions)") ///
    file("`charts'/annual_payroll_growth_leaders.png") period(annual) height(8) ///
    decimals(2) foot("BLS CES. Ranked on 2001–2025 growth. *2026 averages January–October.")

use "`ytdces'", clear
keep if sector_id==0 & year>=2019 & window_end==10
generate double payroll_millions = average_jobs_thousands/1000
lm_endpoint_chart payroll_millions year, panel(industry) ///
    headline("U.S. payroll employment through October 2026") units("Jobs (millions)") ///
    file("`charts'/matched_months_payroll.png") period(ytd) cols(1) height(6) ///
    decimals(1) foot("BLS CES. Each point averages January–October of that year.")

capture program drop lm_endpoint_chart
display as result "Annual trends workbook saved: `annualbook'"
