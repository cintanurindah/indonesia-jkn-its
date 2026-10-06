# Extend the master file to 2019 (phc_master_file_v2.xlsx)
# New downloads (Oct 2026) are in 02_data_raw/2019_update. OOP, CHE, DPT3, MCV1
# and GDP match v1 exactly for 2000-2017, so those years are unchanged. IMR is a
# newer UN IGME release with small revisions, so the whole series is replaced.
# PHC/THE spending (IHME) stops at 2017.

library(tidyverse)
library(readxl)
library(jsonlite)

raw <- "../02_data_raw"

v1 <- read_excel("phc_master_file_v1.xlsx") %>% filter(!is.na(year))

gho <- function(code, ...) {
  fromJSON(file.path(raw, "2019_update", paste0("WHO_", code, "_IDN.json")))$value %>%
    filter(...) %>%
    transmute(year = TimeDim, value = NumericValue)
}

oop  <- gho("GHED_OOPSCHE_SHA2011")
che  <- gho("FINPROTECTION_CATA_TOT_10_POP", Dim1 == "RESIDENCEAREATYPE_TOTL")
imr  <- gho("MDG_0000000001", Dim1 == "SEX_BTSX")
dpt3 <- gho("WHS4_100")
mcv1 <- gho("WHS8_110")

gdp <- fromJSON(file.path(raw, "2019_update/WB_NY.GDP.PCAP.PP.KD_IDN.json"))[[2]] %>%
  transmute(year = as.integer(date), value)

nmr <- read_excel(file.path(raw, "UNICEF/NMR/Neonatal_Mortality_Rates_2024.xlsx"), skip = 14) %>%
  filter(ISO.Code == "IDN", `Uncertainty.Bounds*` == "Median") %>%
  select(matches("^20[01][0-9]\\.5$")) %>%
  pivot_longer(everything(), names_to = "year", values_to = "value") %>%
  mutate(year = as.integer(floor(as.numeric(year))))

mmr_file <- "WHO/MMR/MMR-maternal-deaths-and-LTR_MMEIG-trends_2000-2023_Revised-2025-1.xlsx"

mmr <- read_excel(file.path(raw, mmr_file), sheet = "MMR_country_level", skip = 3) %>%
  filter(Country == "Indonesia") %>%
  select(matches("^20[01][0-9]$")) %>%
  pivot_longer(everything(), names_to = "year", values_to = "value") %>%
  mutate(year = as.integer(year))

# master file units: shares as proportions, NMR/IMR per 100 live births
new <- tibble(year = 2000:2019) %>%
  left_join(oop  %>% transmute(year, oop_share = value / 100), by = "year") %>%
  left_join(che  %>% transmute(year, che_incidence = value / 100), by = "year") %>%
  left_join(dpt3 %>% transmute(year, dpt3_coverage = value / 100), by = "year") %>%
  left_join(mcv1 %>% transmute(year, mcv1_coverage = value / 100), by = "year") %>%
  left_join(nmr  %>% transmute(year, nmr = value / 100), by = "year") %>%
  left_join(imr  %>% transmute(year, imr = value / 100), by = "year") %>%
  left_join(mmr  %>% transmute(year, mmr = value), by = "year") %>%
  left_join(gdp  %>% transmute(year, gdp_pc = value), by = "year")

v2 <- v1 %>%
  bind_rows(tibble(year = 2018:2019)) %>%
  rows_update(new, by = "year") %>%
  arrange(year)

# sanity checks against v1
stopifnot(nrow(v2) == 20,
          all.equal(v2$oop_share[1:18], v1$oop_share),
          all.equal(v2$dpt3_coverage[1:18], v1$dpt3_coverage),
          all.equal(v2$nmr[1:18], v1$nmr))

v2 %>% select(year, names(new)) %>% filter(year >= 2013) %>% print(width = Inf)

openxlsx::write.xlsx(v2, "phc_master_file_v2.xlsx")
