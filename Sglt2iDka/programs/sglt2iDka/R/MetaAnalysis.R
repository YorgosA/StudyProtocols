#' @export
doMetaAnalysis <- function(outputFolders,
                           maOutputFolder,
                           maxCores) {

  OhdsiRTools::logInfo("Performing meta-analysis")
  resultsFolder <- file.path(maOutputFolder, "results")
  if (!file.exists(resultsFolder))
    dir.create(resultsFolder, recursive = TRUE)
  shinyDataFolder <- file.path(resultsFolder, "shinyData")
  if (!file.exists(shinyDataFolder))
    dir.create(shinyDataFolder)

  loadResults <- function(outputFolder) {
    files <- list.files(file.path(outputFolder, "results"), pattern = "results_.*.csv", full.names = TRUE)
    OhdsiRTools::logInfo("Loading ", files[1], " for meta-analysis")
    return(read.csv(files[1]))
  }
  allResults <- lapply(outputFolders, loadResults)
  allResults <- do.call(rbind, allResults)
  groups <- split(allResults, paste(allResults$targetId, allResults$comparatorId, allResults$analysisId))
  cluster <- OhdsiRTools::makeCluster(min(maxCores, 12))
  results <- OhdsiRTools::clusterApply(cluster, groups, computeGroupMetaAnalysis, shinyDataFolder = shinyDataFolder)
  OhdsiRTools::stopCluster(cluster)
  results <- do.call(rbind, results)

  fileName <-  file.path(resultsFolder, paste0("results_Meta-analysis.csv"))
  write.csv(results, fileName, row.names = FALSE, na = "")

  hois <- results[results$type == "Outcome of interest", ]
  fileName <-  file.path(shinyDataFolder, paste0("resultsHois_Meta-analysis.rds"))
  saveRDS(hois, fileName)

  ncs <- results[results$type == "Negative control", c("targetId", "comparatorId", "outcomeId", "analysisId", "database", "logRr", "seLogRr")]
  fileName <-  file.path(shinyDataFolder, paste0("resultsNcs_Meta-analysis.rds"))
  saveRDS(ncs, fileName)
}

computeGroupMetaAnalysis <- function(group,
                                     shinyDataFolder) {

  # group <- groups[["124 74 2"]]
  analysisId <- group$analysisId[1]
  targetId <- group$targetId[1]
  comparatorId <- group$comparatorId[1]
  OhdsiRTools::logTrace("Performing meta-analysis for target ", targetId, ", comparator ", comparatorId, ", analysis", analysisId)
  outcomeGroups <- split(group, group$outcomeId)
  outcomeGroupResults <- lapply(outcomeGroups, computeSingleMetaAnalysis)
  groupResults <- do.call(rbind, outcomeGroupResults)
  negControlSubset <- groupResults[groupResults$type == "Negative control", ]
  validNcs <- sum(!is.na(negControlSubset$seLogRr))
  if (validNcs >= 5) {
    fileName <- file.path(shinyDataFolder, paste0("null_a", analysisId,
                                                  "_t", targetId,
                                                  "_c", comparatorId,
                                                  "_Meta-analysis.rds"))
    null <- EmpiricalCalibration::fitMcmcNull(negControlSubset$logRr, negControlSubset$seLogRr)
    saveRDS(null, fileName)
    calibratedP <- EmpiricalCalibration::calibrateP(null = null,
                                                    logRr = groupResults$logRr,
                                                    seLogRr = groupResults$seLogRr)
    groupResults$calP <- calibratedP$p
    groupResults$calP_lb95ci <- calibratedP$lb95ci
    groupResults$calP_ub95ci <- calibratedP$ub95ci
    mcmc <- attr(null, "mcmc")
    groupResults$null_mean <- mean(mcmc$chain[,1])
    groupResults$null_sd <- 1/sqrt(mean(mcmc$chain[,2]))
  } else {
    groupResults$calP <- NA
    groupResults$calP_lb95ci <- NA
    groupResults$calP_ub95ci <- NA
    groupResults$null_mean <- NA
    groupResults$null_sd <- NA
  }
  return(groupResults)
}

computeSingleMetaAnalysis <- function(outcomeGroup) {

  # outcomeGroup <- outcomeGroups[[2]]
  maRow <- outcomeGroup[1, ]
  outcomeGroup <- outcomeGroup[!is.na(outcomeGroup$seLogRr), ]
  if (nrow(outcomeGroup) == 0) {
    maRow$treated <- 0
    maRow$comparator <- 0
    maRow$treatedDays <- 0
    maRow$comparatorDays <- 0
    maRow$eventsTreated <- 0
    maRow$eventsComparator <- 0
    maRow$rr <- NA
    maRow$ci95lb <- NA
    maRow$ci95ub <- NA
    maRow$p <- NA
    maRow$logRr <- NA
    maRow$seLogRr <- NA
    maRow$i2 <- NA
  } else if (nrow(outcomeGroup) == 1) {
    maRow <- outcomeGroup[1, ]
    maRow$i2 <- 0
  } else {
    maRow$treated <- sum(outcomeGroup$treated)
    maRow$comparator <- sum(outcomeGroup$comparator)
    maRow$treatedDays <- sum(outcomeGroup$treatedDays)
    maRow$comparatorDays <- sum(outcomeGroup$comparatorDays)
    maRow$eventsTreated <- sum(outcomeGroup$eventsTreated)
    maRow$eventsComparator <- sum(outcomeGroup$eventsComparator)
    meta <- meta::metagen(outcomeGroup$logRr, outcomeGroup$seLogRr, sm = "RR", hakn = FALSE)
    s <- summary(meta)
    maRow$i2 <- s$I2$TE
    if (maRow$i2 < .40) {
      rnd <- s$random
      maRow$rr <- exp(rnd$TE)
      maRow$ci95lb <- exp(rnd$lower)
      maRow$ci95ub <- exp(rnd$upper)
      maRow$p <- rnd$p
      maRow$logRr <- rnd$TE
      maRow$seLogRr <- rnd$seTE
    } else {
      maRow$rr <- NA
      maRow$ci95lb <- NA
      maRow$ci95ub <- NA
      maRow$p <- NA
      maRow$logRr <- NA
      maRow$seLogRr <- NA
    }
  }
  if (is.na(maRow$logRr)) {
    maRow$mdrr <- NA
  } else {
    alpha <- 0.05
    power <- 0.8
    z1MinAlpha <- qnorm(1 - alpha/2)
    zBeta <- -qnorm(1 - power)
    pA <- maRow$treated / (maRow$treated + maRow$comparator)
    pB <- 1 - pA
    totalEvents <- maRow$eventsTreated + maRow$eventsComparator
    maRow$mdrr <- exp(sqrt((zBeta + z1MinAlpha)^2/(totalEvents * pA * pB)))
  }
  maRow$database <- "Meta-analysis"
  return(maRow)
}

