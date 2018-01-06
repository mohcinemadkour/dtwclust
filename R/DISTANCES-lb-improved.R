#' Lemire's improved DTW lower bound
#'
#' This function calculates an improved lower bound (LB) on the Dynamic Time Warp (DTW) distance
#' between two time series. It uses a Sakoe-Chiba constraint.
#'
#' @export
#'
#' @param x A time series (reference).
#' @param y A time series with the same length as `x` (query).
#' @param window.size Window size for envelope calculation. See details.
#' @param norm Vector norm. Either `"L1"` for Manhattan distance or `"L2"` for Euclidean.
#' @param lower.env Optionally, a pre-computed lower envelope for **`y`** can be provided (non-proxy
#'   version only). See [compute_envelope()].
#' @param upper.env Optionally, a pre-computed upper envelope for **`y`** can be provided (non-proxy
#'   version only). See [compute_envelope()].
#' @param force.symmetry If `TRUE`, a second lower bound is calculated by swapping `x` and `y`, and
#'   whichever result has a *higher* distance value is returned. The proxy version can only work if
#'   a square matrix is obtained, but use carefully.
#' @template error-check
#'
#' @details
#'
#' The reference time series should go in `x`, whereas the query time series should go in `y`.
#'
#' If the envelopes are provided, they should be provided together. If either one is missing, both
#' will be computed.
#'
#' @template window
#'
#' @return The improved lower bound for the DTW distance.
#'
#' @template proxy
#'
#' @section Note:
#'
#' The lower bound is only defined for time series of equal length and is **not** symmetric.
#'
#' If you wish to calculate the lower bound between several time series, it would be better to use
#' the version registered with the `proxy` package, since it includes some small optimizations. The
#' convention mentioned above for references and queries still holds. See the examples.
#'
#' The proxy version of `force.symmetry` should only be used when only `x` is provided or both `x`
#' and `y` are identical. It compares the lower and upper triangular of the resulting distance
#' matrix and forces symmetry in such a way that the tightest lower bound is obtained.
#'
#' @references
#'
#' Lemire D (2009). ``Faster retrieval with a two-pass dynamic-time-warping lower bound .'' *Pattern
#' Recognition*, **42**(9), pp. 2169 - 2180. ISSN 0031-3203,
#' \url{http://dx.doi.org/10.1016/j.patcog.2008.11.030},
#' \url{http://www.sciencedirect.com/science/article/pii/S0031320308004925}.
#'
#' @examples
#'
#' # Sample data
#' data(uciCT)
#'
#' # Lower bound distance between two series
#' d.lbi <- lb_improved(CharTraj[[1]], CharTraj[[2]], window.size = 20)
#'
#' # Corresponding true DTW distance
#' d.dtw <- dtw(CharTraj[[1]], CharTraj[[2]],
#'              window.type = "sakoechiba", window.size = 20)$distance
#'
#' d.lbi <= d.dtw
#'
#' # Calculating the LB between several time series using the 'proxy' package
#' # (notice how both argments must be lists)
#' D.lbi <- proxy::dist(CharTraj[1], CharTraj[2:5], method = "LB_Improved",
#'                      window.size = 20, norm = "L2")
#'
#' # Corresponding true DTW distance
#' D.dtw <- proxy::dist(CharTraj[1], CharTraj[2:5], method = "dtw_basic",
#'                      norm = "L2", window.size = 20)
#'
#' D.lbi <= D.dtw
#'
lb_improved <- function(x, y, window.size = NULL, norm = "L1",
                        lower.env = NULL, upper.env = NULL,
                        force.symmetry = FALSE, error.check = TRUE)
{
    norm <- match.arg(norm, c("L1", "L2"))
    if (length(x) != length(y)) stop("The series must have the same length")
    window.size <- check_consistency(window.size, "window")
    if (is_multivariate(list(x, y))) stop("lb_improved does not support multivariate series.")
    if (error.check) {
        check_consistency(x, "ts")
        check_consistency(y, "ts")
    }

    if (is.null(lower.env) || is.null(upper.env)) {
        envelopes <- compute_envelope(y, window.size = window.size, error.check = FALSE)
        lower.env <- envelopes$lower
        upper.env <- envelopes$upper

    } else {
        check_consistency(lower.env, "ts")
        check_consistency(upper.env, "ts")
        if (length(lower.env) != length(x))
            stop("Length mismatch between 'x' and the lower envelope")
        if (length(upper.env) != length(x))
            stop("Length mismatch between 'x' and the upper envelope")
    }

    p <- switch(norm, L1 = 1L, L2 = 2L)
    d <- .Call(C_lbi, x, y, window.size, p, lower.env, upper.env, PACKAGE = "dtwclust")

    if (force.symmetry) {
        d2 <- lb_improved(x = y, y = x, window.size = window.size, norm = norm, error.check = FALSE)
        if (d2 > d) d <- d2
    }

    # return
    d
}

# ==================================================================================================
# Loop without using native 'proxy' looping (to avoid multiple calculations of the envelope)
# ==================================================================================================

#' @importFrom bigmemory describe
#' @importFrom bigmemory is.big.matrix
#'
lb_improved_proxy <- function(x, y = NULL, window.size = NULL, norm = "L1", ...,
                              force.symmetry = FALSE, pairwise = FALSE, error.check = TRUE)
{
    norm <- match.arg(norm, c("L1", "L2"))
    window.size <- check_consistency(window.size, "window")
    dots <- list(...)
    x <- tslist(x)
    if (error.check) check_consistency(x, "tslist")

    if (is.null(y)) {
        y <- x

    } else {
        y <- tslist(y)
        if (error.check) check_consistency(y, "tslist")
    }

    if (is_multivariate(c(x,y))) stop("lb_improved does not support multivariate series.")
    pairwise <- isTRUE(pairwise)
    dim_out <- c(length(x), length(y))
    dim_names <- list(names(x), names(y))

    # Get appropriate matrix/big.matrix
    D <- allocate_distmat(length(x), length(y), pairwise, FALSE) # UTILS-utils.R

    envelopes <- lapply(y, function(s) { compute_envelope(s, window.size, error.check = FALSE) })
    lower.env <- lapply(envelopes, "[[", "lower")
    upper.env <- lapply(envelopes, "[[", "upper")
    lower.env <- split_parallel(lower.env)
    upper.env <- split_parallel(upper.env)
    y <- split_parallel(y)

    # Wrap as needed for foreach
    if (pairwise) {
        x <- split_parallel(x)
        validate_pairwise(x, y)
        validate_pairwise(x, lower.env)
        validate_pairwise(x, upper.env)
        endpoints <- attr(x, "endpoints")

    } else {
        x <- lapply(1L:(foreach::getDoParWorkers()), function(dummy) { x })
        endpoints <- attr(y, "endpoints")
    }

    if (bigmemory::is.big.matrix(D)) {
        D_desc <- bigmemory::describe(D)
        noexport <- "D"
        packages <- c("dtwclust", "bigmemory")

    } else {
        D_desc <- NULL
        noexport <- ""
        packages <- c("dtwclust")
    }

    # Calculate distance matrix
    foreach_extra_args <- list(lower.env = lower.env, upper.env = upper.env)
    symmetric <- FALSE # needed to evaluate expression below
    dots$window.size <- window.size
    dots$norm <- norm
    dots$lower.env <- quote(lower.env)
    dots$upper.env <- quote(upper.env)
    .distfun_ <- lbi_loop
    eval(foreach_loop_expression) # UTILS-expressions-proxy.R

    if (pairwise) {
        class(D) <- "pairdist"

    } else {
        if (is.null(dim(D))) dim(D) <- dim_out
        dimnames(D) <- dim_names
        class(D) <- "crossdist"
    }

    if (force.symmetry && !pairwise) {
        if (nrow(D) != ncol(D))
            warning("Unable to force symmetry. Resulting distance matrix is not square.")
        else
            .Call(C_force_lb_symmetry, D, PACKAGE = "dtwclust")
    }

    attr(D, "method") <- "LB_Improved"
    # return
    D
}

# ==================================================================================================
# Wrapper for C++
# ==================================================================================================

lbi_loop <- function(d, x, y, symmetric, pairwise, endpoints, bigmat, ...,
                     lower.env, upper.env, window.size, norm)
{
    # this is never symmetric
    fill_type <- if (pairwise) "PAIRWISE" else "GENERAL"
    mat_type <- if (bigmat) "BIG_MATRIX" else "R_MATRIX"
    distargs <- list()
    distargs$p <- switch(norm, "L1" = 1L, "L2" = 2L)
    distargs$len <- length(x[[1L]])
    distargs$window.size <- window.size
    distargs$lower.env <- lower.env
    distargs$upper.env <- upper.env
    .Call(C_distmat_loop,
          d, x, y,
          "LBI", distargs,
          fill_type, mat_type, endpoints,
          PACKAGE = "dtwclust")
}