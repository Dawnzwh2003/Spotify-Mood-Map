AUDIO <- c("danceability", "energy", "loudness", "speechiness", "acousticness",
           "instrumentalness", "liveness", "valence", "tempo")
UNIT <- setdiff(AUDIO, c("loudness", "tempo"))
qvalue <- function(x, p) if (!length(x)) NA_real_ else unname(quantile(x, p, na.rm=TRUE))

clean_tracks <- function(raw) {
  needed <- c("track_id", "valence", "energy")
  if (!all(needed %in% names(raw))) stop("Missing columns: ", paste(setdiff(needed, names(raw)), collapse=", "))
  if (!nrow(raw)) stop("Empty input file")
  d <- raw
  d$track_id <- trimws(as.character(d$track_id))
  good_id <- !is.na(d$track_id) & nzchar(d$track_id)
  d <- d[good_id, , drop=FALSE]
  if (!nrow(d)) stop("No valid track IDs")
  if (!"tempo" %in% names(d)) d$tempo <- NA_real_
  audio_columns <- intersect(AUDIO, names(d))
  audit <- data.frame(item=c("input_rows", "rows_missing_track_id"),
                      n=c(nrow(raw), sum(!good_id)))
  for (f in audio_columns) {
    x <- if (is.numeric(d[[f]])) as.numeric(d[[f]]) else suppressWarnings(as.numeric(as.character(d[[f]])))
    bad <- !is.finite(x)
    if (f %in% UNIT) bad <- bad | x < 0 | x > 1
    if (f == "tempo") bad <- bad | x <= 0
    audit <- rbind(audit, data.frame(item=paste0("missing_or_invalid_", f), n=sum(bad)))
    x[bad] <- NA_real_
    d[[f]] <- x
  }
  if (!"track_popularity" %in% names(d)) d$track_popularity <- NA_real_
  d$track_popularity <- suppressWarnings(as.numeric(as.character(d$track_popularity)))
  d$track_popularity[!is.finite(d$track_popularity) | d$track_popularity < 0 |
                       d$track_popularity > 100] <- NA_real_
  for (f in c("track_name", "track_artist")) {
    if (!f %in% names(d)) d[[f]] <- ""
    d[[f]] <- as.character(d[[f]])
    d[[f]][is.na(d[[f]])] <- ""
  }
  signature <- apply(d[, audio_columns, drop=FALSE], 1, function(x) paste(x, collapse="|"))
  variants <- unique(data.frame(track_id=d$track_id, signature=signature))
  counts <- table(variants$track_id)
  conflicts <- data.frame(track_id=names(counts)[counts > 1],
                          distinct_audio_rows=as.integer(counts[counts > 1]))
  axis_ok <- complete.cases(d[, c("valence", "energy")])
  completeness <- rowSums(!is.na(d[, audio_columns, drop=FALSE]))
  stable <- paste(signature, d$track_name, d$track_artist, d$track_popularity, sep="|")
  d <- d[order(d$track_id, -as.integer(axis_ok), -completeness, stable, method="radix"), , drop=FALSE]
  duplicate_rows <- sum(duplicated(d$track_id))
  d <- d[!duplicated(d$track_id), , drop=FALSE]
  valid <- complete.cases(d[, c("valence", "energy")])
  audit <- rbind(audit, data.frame(item=c("duplicate_id_rows_removed", "distinct_track_ids",
      "ids_with_conflicting_audio", "unique_tracks_missing_axes", "mapped_tracks"),
      n=c(duplicate_rows, nrow(d), nrow(conflicts), sum(!valid), sum(valid))))
  d <- d[valid, , drop=FALSE]
  if (!nrow(d)) stop("No tracks have valid energy and valence")
  rownames(d) <- NULL
  list(data=d, audit=audit, conflicts=conflicts)
}

transform_axes <- function(d) {
  if (!all(c("valence", "energy") %in% names(d))) {
    stop("Mapping needs valence and energy")
  }
  d$x <- d$valence
  d$y <- d$energy
  xy <- as.matrix(d[, c("x", "y"), drop = FALSE])
  if (!is.numeric(xy) || any(!is.finite(xy))) stop("Invalid coordinate values")
  if (any(xy < 0 | xy > 1)) stop("Coordinates outside [0,1]")
  d
}

add_songs <- function(catalogue, new_data) {
  incoming <- transform_axes(clean_tracks(new_data)$data)
  incoming <- incoming[!incoming$track_id %in% catalogue$track_id, , drop = FALSE]
  if (!nrow(incoming)) return(catalogue)
  columns <- union(names(catalogue), names(incoming))
  for (name in setdiff(columns, names(catalogue))) catalogue[[name]] <- NA
  for (name in setdiff(columns, names(incoming))) incoming[[name]] <- NA
  result <- rbind(catalogue[, columns, drop = FALSE], incoming[, columns, drop = FALSE])
  rownames(result) <- NULL
  result
}

select_song <- function(catalogue, tap, previous_id=NULL, recent_ids=character(),
                        mode=c("nearest", "smooth"), epsilon=.03, max_candidates=20L,
                        sparse_cutoff=.10) {
  mode <- match.arg(mode)
  if (length(tap)!=2 || any(!is.finite(tap)) || any(tap<0 | tap>1)) stop("tap must be c(x,y) in [0,1]")
  if (!nrow(catalogue)) stop("Empty catalogue")
  if (anyDuplicated(catalogue$track_id)) stop("Catalogue must have unique track IDs")
  if (any(!is.finite(as.matrix(catalogue[,c("x","y")])))) stop("Invalid catalogue coordinates")
  if (length(epsilon)!=1 || !is.finite(epsilon) || epsilon<0) stop("Invalid epsilon")
  if (length(max_candidates)!=1 || !is.finite(max_candidates) || max_candidates<1 || max_candidates!=as.integer(max_candidates)) stop("Invalid candidate count")
  distance <- sqrt((catalogue$x-tap[1])^2+(catalogue$y-tap[2])^2)
  nearest <- min(distance)
  candidates <- which(distance <= nearest+epsilon+1e-12)
  candidates <- candidates[order(distance[candidates], catalogue$track_id[candidates], method="radix")]
  candidates <- head(candidates, max_candidates)
  chosen <- candidates[1]
  pi <- if (length(previous_id)==1) match(previous_id, catalogue$track_id) else NA_integer_
  if (mode=="smooth" && !is.na(pi)) {
    pool <- candidates[!catalogue$track_id[candidates] %in% c(previous_id,recent_ids)]
    if (!length(pool)) pool <- candidates[!catalogue$track_id[candidates] %in% previous_id]
    if (!length(pool)) pool <- candidates
    if (is.finite(catalogue$tempo[pi])) {
      bpm_gap <- abs(catalogue$tempo[pool]-catalogue$tempo[pi])
      bpm_gap[!is.finite(bpm_gap)] <- Inf
      score <- bpm_gap/30 + (distance[pool]-nearest)/max(epsilon,1e-12)
      chosen <- pool[order(score, distance[pool], catalogue$track_id[pool], method="radix")][1]
    } else chosen <- pool[1]
  }
  answer <- catalogue[chosen, , drop=FALSE]
  answer$tap_distance <- distance[chosen]
  answer$nearest_distance <- nearest
  answer$excess_distance <- distance[chosen]-nearest
  answer$sparse_region <- distance[chosen] > sparse_cutoff
  answer$candidate_count <- length(candidates)
  answer
}

make_paths <- function(n=61L) {
  t <- seq(.05,.95,length.out=n)
  list(horizontal_low=cbind(t,.25), horizontal_mid=cbind(t,.5),
       vertical_mid=cbind(.5,t), diagonal=cbind(t,t), antidiagonal=cbind(t,1-t))
}

evaluate_paths <- function(cat, mode, epsilon=.03, n=61L) {
  out <- list(); k <- 0L
  for (name in names(make_paths(n))) {
    p <- make_paths(n)[[name]]
    previous <- NULL; recent <- character()
    for (i in seq_len(nrow(p))) {
      s <- select_song(cat,p[i,],previous_id=if(is.null(previous)) NULL else previous$track_id,
                       recent_ids=recent,mode=mode,epsilon=epsilon)
      changed <- if(is.null(previous)) NA else s$track_id != previous$track_id
      jump <- if(is.null(previous)) NA_real_ else abs(s$tempo-previous$tempo)
      k <- k+1L
      out[[k]] <- data.frame(method="direct", mode=mode, epsilon=epsilon, path=name, step=i,
          tap_x=p[i,1],tap_y=p[i,2],track_id=s$track_id, track_name=s$track_name,
          track_artist=s$track_artist,x=s$x,y=s$y,energy=s$energy,valence=s$valence,
          tempo=s$tempo,distance=s$tap_distance,excess=s$excess_distance,
          sparse=s$sparse_region,changed=changed,bpm_jump=jump,
          valence_jump=if(is.null(previous)) NA_real_ else abs(s$valence-previous$valence),
          energy_jump=if(is.null(previous)) NA_real_ else abs(s$energy-previous$energy))
      recent <- tail(c(recent,s$track_id),5L)
      previous <- s
    }
  }
  do.call(rbind,out)
}

summarize_paths <- function(log) {
  changed <- log$changed %in% TRUE
  jumps <- log$bpm_jump[changed & is.finite(log$bpm_jump)]
  data.frame(method=log$method[1],mode=log$mode[1],epsilon=log$epsilon[1],
      taps=nrow(log),changes=sum(changed),
      repeat_rate=mean(!log$changed,na.rm=TRUE),
      median_bpm_jump_changed=if(length(jumps)) median(jumps) else NA_real_,
      p90_bpm_jump_changed=qvalue(jumps,.9),
      share_changed_jumps_over30=if(length(jumps)) mean(jumps>30) else NA_real_,
      median_valence_jump_changed=qvalue(log$valence_jump[changed],.5),
      median_energy_jump_changed=qvalue(log$energy_jump[changed],.5),
      mean_tap_distance=mean(log$distance),p95_tap_distance=qvalue(log$distance,.95),
      max_excess_distance=max(log$excess),sparse_share=mean(log$sparse))
}

grid_coverage <- function(cat, n=31L) {
  grid <- expand.grid(x=seq(0,1,length.out=n),y=seq(0,1,length.out=n))
  grid$distance <- vapply(seq_len(nrow(grid)),function(i)
      min(sqrt((cat$x-grid$x[i])^2+(cat$y-grid$y[i])^2)),numeric(1))
  list(grid=grid,summary=data.frame(method="direct",grid_points=nrow(grid),
      median_distance=median(grid$distance),p95_distance=qvalue(grid$distance,.95),
      max_distance=max(grid$distance),continuous_distance_upper_bound=max(grid$distance)+sqrt(2)/(2*(n-1)),
      share_within_005=mean(grid$distance<=.05),
      share_farther_than_010=mean(grid$distance>.10)))
}

save_figure <- function(out,name,draw,width=9,height=6) {
  png(file.path(out,paste0(name,".png")),width=width*160,height=height*160,res=160)
  tryCatch(draw(),finally=dev.off())
  pdf(file.path(out,paste0(name,".pdf")),width=width,height=height)
  tryCatch(draw(),finally=dev.off())
}

run_analysis <- function(csv_path, out = "outputs") {
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  raw <- read.csv(csv_path, stringsAsFactors = FALSE, check.names = FALSE, encoding = "UTF-8")
  cleaned <- clean_tracks(raw)
  catalogue <- transform_axes(cleaned$data)

  write.csv(cleaned$audit, file.path(out, "data_audit.csv"), row.names = FALSE)
  write.csv(cleaned$conflicts, file.path(out, "duplicate_audio_conflicts.csv"), row.names = FALSE)
  saveRDS(catalogue, file.path(out, "catalogue.rds"))
  write.csv(catalogue[, c("track_id", "track_name", "track_artist", "x", "y", "tempo", "track_popularity")],
            file.path(out, "song_coordinates.csv"), row.names = FALSE)

  features <- intersect(AUDIO, names(catalogue))
  features <- features[vapply(catalogue[, features, drop = FALSE], function(x) {
    sum(is.finite(x)) >= 2 && isTRUE(sd(x, na.rm = TRUE) > 0)
  }, logical(1))]
  correlations <- cor(catalogue[, features, drop = FALSE], method = "spearman", use = "pairwise.complete.obs")
  write.csv(correlations, file.path(out, "audio_spearman_correlations.csv"))

  nearest_log <- evaluate_paths(catalogue, mode = "nearest")
  smooth_log <- evaluate_paths(catalogue, mode = "smooth")
  path_log <- rbind(nearest_log, smooth_log)
  performance <- rbind(summarize_paths(nearest_log), summarize_paths(smooth_log))
  write.csv(path_log, file.path(out, "path_selections.csv"), row.names = FALSE)
  write.csv(performance, file.path(out, "retrieval_comparison.csv"), row.names = FALSE)

  groups <- split(path_log, interaction(path_log$mode, path_log$path, drop = TRUE))
  per_path <- do.call(rbind, lapply(groups, function(g) {
    cbind(path = g$path[1], summarize_paths(g))
  }))
  write.csv(per_path, file.path(out, "per_path_retrieval.csv"), row.names = FALSE)

  coverage <- grid_coverage(catalogue)
  write.csv(coverage$grid, file.path(out, "coverage_grid.csv"), row.names = FALSE)
  write.csv(coverage$summary, file.path(out, "coverage_summary.csv"), row.names = FALSE)

  sensitivity <- do.call(rbind, lapply(c(0, .01, .03, .05), function(e) {
    summarize_paths(evaluate_paths(catalogue, mode = "smooth", epsilon = e))
  }))
  write.csv(sensitivity, file.path(out, "locality_sensitivity.csv"), row.names = FALSE)

  taps <- rbind(c(.1, .1), c(.1, .9), c(.9, .1), c(.9, .9), c(.5, .5))
  examples <- do.call(rbind, lapply(seq_len(nrow(taps)), function(i) {
    selected <- select_song(catalogue, taps[i, ])
    cbind(data.frame(tap_x = taps[i, 1], tap_y = taps[i, 2]),
          selected[, c("track_id", "track_name", "track_artist", "x", "y", "tempo", "tap_distance", "sparse_region")])
  }))
  write.csv(examples, file.path(out, "example_tap_songs.csv"), row.names = FALSE)

  save_figure(out, "fig1_feature_relationships", function() {
    par(mar = c(10, 9, 3, 2))
    colors <- colorRampPalette(c("#2166ac", "white", "#b2182b"))(101)
    positions <- seq_along(features)
    image(positions, positions, correlations, zlim = c(-1, 1), col = colors,
          axes = FALSE, xlab = "", ylab = "", main = "Audio features have different relationships")
    axis(1, positions, features, las = 2)
    axis(2, positions, features, las = 2)
    for (i in positions) for (j in positions) {
      text(i, j, sprintf("%.2f", correlations[i, j]), cex = .65)
    }
  }, 9, 9)

  save_figure(out, "fig2_interpretable_mood_map", function() {
    par(mar = c(5, 5, 4, 2), xaxs = "i", yaxs = "i")
    smoothScatter(catalogue$x, catalogue$y, xlim = c(0, 1), ylim = c(0, 1), nrpoints = 0,
                  xlab = "Valence: less positive to more positive", ylab = "Energy: low to high",
                  main = "Valence and energy give the map clear meanings",
                  colramp = colorRampPalette(c("#ffffff", "#a5d8dd", "#167d9a", "#163a5f")))
    abline(h = .5, v = .5, col = "grey60", lty = 3)
    text(c(.16, .16, .82, .82), c(.12, .88, .12, .88),
         c("Lower energy\nLower valence", "Higher energy\nLower valence",
           "Lower energy\nHigher valence", "Higher energy\nHigher valence"),
         cex = .8, col = c("#163a5f", "white", "#163a5f", "white"))
  })

  save_figure(out, "fig3_screen_coverage", function() {
    par(mar = c(5, 5, 4, 5))
    ticks <- sort(unique(coverage$grid$x))
    distances <- matrix(coverage$grid$distance, length(ticks), length(ticks))
    image(ticks, ticks, distances, col = hcl.colors(50, "YlOrRd", rev = TRUE),
          xlab = "Valence", ylab = "Energy",
          main = "Coverage is broad, with larger gaps near low energy")
    contour(ticks, ticks, distances, levels = c(.05, .1, .2), add = TRUE, drawlabels = TRUE)
    mtext("Contour labels = map distance; darker shading = farther", side = 3, cex = .7)
  })

  save_figure(out, "fig4_path_tempo", function() {
    par(mfrow = c(2, 1), mar = c(4, 5, 3, 1))
    limits <- range(path_log$tempo, na.rm = TRUE)
    for (mode in c("nearest", "smooth")) {
      selected <- path_log[path_log$mode == mode & path_log$path == "horizontal_mid", ]
      plot(selected$tap_x, selected$tempo, type = "o", pch = 16, cex = .5,
           col = if (mode == "nearest") "#a54536" else "#167d9a", ylim = limits,
           xlab = "Tap valence at energy = 0.5", ylab = "Selected tempo (BPM)",
           main = paste("Full catalogue:", mode))
    }
  })

  save_figure(out, "fig5_locality_tradeoff", function() {
    par(mfrow = c(1, 2), mar = c(5, 5, 4, 2))
    plot(sensitivity$epsilon, sensitivity$median_bpm_jump_changed, type = "b", pch = 16, col = "#167d9a",
         xlab = "Allowed extra map distance", ylab = "Median BPM jump when track changes",
         main = "Tempo continuity")
    plot(sensitivity$epsilon, sensitivity$mean_tap_distance, type = "b", pch = 16, col = "#a54536",
         xlab = "Allowed extra map distance", ylab = "Mean distance from requested point",
         main = "Location fidelity")
  }, 11, 5)

  summary <- capture.output({
    cat("STSCI 5954 | direct valence-energy map\n\n")
    cat("Input MD5:", unname(tools::md5sum(csv_path)), "\n")
    print(cleaned$audit, row.names = FALSE)
    cat("\nMapped unique songs:", nrow(catalogue), "\n")
    cat("Valid tempos:", sum(is.finite(catalogue$tempo)), "\n")
    cat("Popularity zero:", sum(catalogue$track_popularity == 0, na.rm = TRUE),
        "Missing:", sum(is.na(catalogue$track_popularity)), "\n")
    cat("\nFull catalogue Spearman correlations:\n")
    print(round(correlations, 3))
    cat("\nFull catalogue screen coverage:\n")
    print(coverage$summary, row.names = FALSE)
    cat("\nFull catalogue path retrieval:\n")
    print(performance, row.names = FALSE)
    cat("\nExploratory locality sensitivity:\n")
    print(sensitivity, row.names = FALSE)
    cat("\nCoordinates use observed valence and energy. No training or outcome prediction is performed.\n")
    cat("Tempo and coverage are offline diagnostics, not listening-satisfaction measurements.\n")
  })
  writeLines(summary, file.path(out, "results_summary.txt"))
  writeLines(capture.output(sessionInfo()), file.path(out, "sessionInfo.txt"))
  message("Done. Results: ", normalizePath(out, winslash = "/"))
  invisible(list(catalogue = catalogue, performance = performance,
                 coverage = coverage$summary, sensitivity = sensitivity))
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (!length(args)) stop("Usage: Rscript mood_map.R spotify_songs.csv [output_directory]")
  run_analysis(args[1], if (length(args) >= 2) args[2] else "outputs")
}
