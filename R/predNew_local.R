utils::globalVariables(c("year", "month", "station.id", "lon", "lat", "elev2"))

#' Prediction at new locations based on the fitting results in memory.
#'
#' The prediction at new locations are calculated based on the fitting results
#' saved in memory based on the original dataset.
#'
#' @param newdata
#'     A data.frame includes all locations' longitude, latitude, and elevation,
#'     where the prediction is to be calculated.
#' @param original
#'     The data.frame which contains all fitting results of original dataset. The data.frame
#'     is saved in memory, not on HDFS.
#' @param mlcontrol
#'     Should be a list object generated from \code{spacetime.control} function.
#'     The list including all necessary smoothing parameters of nonparametric fitting.
#' @author
#'     Xiaosu Tong
#' @export
#' @seealso
#'     \code{\link{spacetime.control}}, \code{\link{mapreduce.control}}
#'
#' @examples
#' \dontrun{
#'     library(maps)
#'     library(Spaloess)
#'     library(datadr)
#'     new.grid <- expand.grid(
#'       lon = seq(-126, -67, by = 1),
#'       lat = seq(25, 49, by = 1)
#'     )
#'     instate <- !is.na(map.where("state", new.grid$lon, new.grid$lat))
#'     new.grid <- new.grid[instate, ]
#'
#'     elev.fit <- spaloess( elev ~ lon + lat,
#'       data = station_info,
#'       degree = 2,
#'       span = 0.05,
#'       distance = "Latlong",
#'       normalize = FALSE,
#'       napred = FALSE,
#'       alltree = FALSE,
#'       family="symmetric",
#'       control=loess.control(surface = "direct")
#'     )
#'     grid.fit <- predloess(
#'       object = elev.fit,
#'       newdata = data.frame(
#'         lon = new.grid$lon,
#'         lat = new.grid$lat
#'       )
#'     )
#'     new.grid$elev <- grid.fit
#'
#'     n <- 5000 # just use 5000 stations as example
#'     set.seed(99)
#'     first_stations <- sample(unique(tmax_all$station.id), n)
#'     small_dt <- subset(tmax_all, station.id %in% first_stations)
#'     small_dt$station.id <- as.character(small_dt$station.id)
#'     small_dt$month <- as.character(small_dt$month)
#'     mlcontrol <- spacetime.control(
#'       vari="tmax", time="date", n=576, n.p=12, stat_n=n, surf = "interpolate",
#'       s.window="periodic", t.window = 241, degree=2, span=0.75, Edeg=0
#'     )
#' 
#'     fitted <- drsstl(
#'       data=small_dt,
#'       output=NULL,
#'       model_control=mlcontrol
#'     )
#'     rst <- predNew_local(
#'       original = recombine(fitted, combRbind), newdata = new.grid, mlcontrol = mlcontrol
#'     )
#' }
predNew_local <- function(original, newdata, mlcontrol=spacetime.control()) {

  if(mlcontrol$Edeg == 2) {
    newdata$elev2 <- log2(newdata$elev + 128)
    original$elev2 <- log2(original$elev + 128)
    fml <- as.formula(paste(mlcontrol$vari, "~ lon + lat + elev2"))
    dropSq <- FALSE
    condParam <- "elev2"
  } else if(mlcontrol$Edeg == 1) {
    original$elev2 <- log2(original$elev + 128)
    newdata$elev2 <- log2(newdata$elev + 128)
    fml <- as.formula(paste(mlcontrol$vari, "~ lon + lat + elev2"))
    dropSq <- "elev2"
    condParam <- "elev2"
  } else if (mlcontrol$Edeg == 0) {
    fml <- as.formula(paste(mlcontrol$vari, "~ lon + lat"))
    dropSq <- FALSE
    condParam <- FALSE
  }

  N <- nrow(newdata)
  if (class(original$station.id) != "character") {
    original$station.id <- as.character(original$station.id)    
  }

  message("First spatial smoothing...")
  rst <- dlply(.data = original
    , .variables = c("year", "month")
    , .fun = function(v) {
        value <- cbind(data.frame(station.id = 1:N), newdata)
        NApred <- any(is.na(v[, mlcontrol$vari]))
        lo.fit <- spaloess(fml,
          data        = v,
          degree      = mlcontrol$degree,
          span        = mlcontrol$span,
          parametric  = condParam,
          drop_square = dropSq,
          family      = mlcontrol$family,
          normalize   = FALSE,
          distance    = "Latlong",
          control     = loess.control(surface = mlcontrol$surf, iterations = mlcontrol$siter, cell = mlcontrol$cell),
          napred      = NApred,
          alltree     = match.arg(mlcontrol$surf, c("interpolate", "direct")) == "interpolate"
        )
        if (mlcontrol$Edeg != 0) {
          newPred <- unname(predloess(
            object = lo.fit,
            newdata = data.frame(
              lon = newdata$lon,
              lat = newdata$lat,
              elev2 = newdata$elev2
            )
          ))
        } else {
          newPred <- unname(predloess(
            object = lo.fit,
            newdata = data.frame(
              lon = newdata$lon,
              lat = newdata$lat
            )
          ))
        }
        value$spaofit <- newPred
        value
      }
  )

  rst <- do.call("rbind", rst)
  time <- strsplit(rownames(rst),"[.]")
  rownames(rst) <- NULL
  rst$year <- as.numeric(unlist(lapply(time, function(r) {
    r[1]
  })))
  rst$month <- unlist(lapply(time, function(r) {
    r[2]
  }))

  message("Temporal fitting...")
  rst <- ddply(.data = rst
    , .variables = "station.id"
    , .fun = function(v) {
        v <- arrange(v, year, match(month, month.abb))
        fit <- stlplus::stlplus(
          x        = v$spaofit,
          t        = 1:nrow(v),
          n.p      = mlcontrol$n.p,
          s.window = mlcontrol$s.window,
          s.degree = mlcontrol$s.degree,
          t.window = mlcontrol$t.window,
          t.degree = mlcontrol$t.degree,
          inner    = mlcontrol$inner,
          outer    = mlcontrol$outer
        )$data
        v <- cbind(v, fit[, c("seasonal", "trend", "remainder")])
        v
    }
  )

  if(mlcontrol$Edeg != 0) {
    fml <- as.formula("remainder ~ lon + lat + elev2")
    tmp <- rbind(
      subset(original, select = c(station.id, lon, lat, elev2, year, month, spaofit, seasonal, trend)),
      subset(rst, select = c(station.id, lon, lat, elev2, year, month, spaofit, seasonal, trend))
    )
  } else {
    fml <- as.formula("remainder ~ lon + lat")
    tmp <- rbind(
      subset(original, select = c(station.id, lon, lat, year, month, spaofit, seasonal, trend)),
      subset(rst, select = c(station.id, lon, lat, year, month, spaofit, seasonal, trend))
    )
  }
  
  message("Second spatial smoothing...")
  rst <- ddply(.data = tmp
    , .variables = c("year", "month")
    , .fun = function(v) {
        v$remainder <- with(v, spaofit - trend - seasonal)
        lo.fit <- spaloess(fml,
          data        = v,
          degree      = mlcontrol$degree,
          span        = mlcontrol$span,
          parametric  = condParam,
          drop_square = dropSq,
          family      = mlcontrol$family,
          normalize   = FALSE,
          distance    = "Latlong",
          control     = loess.control(surface = mlcontrol$surf, iterations = mlcontrol$siter, cell = mlcontrol$cell),
          napred      = FALSE,
          alltree     = match.arg(mlcontrol$surf, c("interpolate", "direct")) == "interpolate"
        )
        v$Rspa <- lo.fit$fitted
        subset(v, station.id %in% 1:N, select = -c(remainder))
      }
  )

  return(rst)

}
