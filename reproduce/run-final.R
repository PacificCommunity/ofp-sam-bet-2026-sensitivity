#!/usr/bin/env Rscript
# Preserved native model files; no R packages or Python runtime.
options(stringsAsFactors = FALSE)
fail <- function(...) stop(..., call. = FALSE)
require_true <- function(x, ...) if (!isTRUE(x)) fail(...)
family <- "sensitivity"
reader_checkout <- NULL
expected_models <- c("caal-0.5-sub-basin","caal-1.0-sub-basin","effort-creep-high","lorenzen-m-scalar-0.062","lorenzen-m-scalar-0.1","pre-mixing-tag-reporting-inclusion","regional-scaling-whole-period","steepness-0.65","steepness-0.80","steepness-0.95","tag-mixing-k-0.1","tag-mixing-k-0.3","tau-1.006738","tau-1.2","tau-1.4","tau-1.6","tau-1.8")
controls <- c("1 1 1", "1 246 1")
dimension_labels <- c("Number of time periods", "Year 1", "Number of regions", "Number of species", "Number of age classes", "Number of recruitments per year")
central_labels <- c(dimension_labels, "Adult biomass", "Adult biomass in absence of fishing", "Adult biomass at MSY", "F multiplier at MSY")
exists_path <- function(path) {
  link <- Sys.readlink(path)
  file.exists(path) || dir.exists(path) || (!is.na(link) && nzchar(link))
}

regular_file <- function(path) {
  info <- file.info(path)
  link <- Sys.readlink(path)
  require_true(nrow(info) == 1L && !is.na(info$isdir) && !info$isdir && file_test("-f", path) &&
                 (is.na(link) || !nzchar(link)), "Expected a regular file: ", path)
  invisible(info)
}

directory <- function(path) {
  info <- file.info(path)
  link <- Sys.readlink(path)
  require_true(nrow(info) == 1L && !is.na(info$isdir) && info$isdir &&
                 (is.na(link) || !nzchar(link)), "Expected an ordinary directory: ", path)
  invisible(path)
}

checked_command <- function(program, args, ...) {
  found <- Sys.which(program)
  require_true(nzchar(found), "Required system command is unavailable: ", program)
  result <- system2(found, args = args, stdout = TRUE, stderr = TRUE, ...)
  status <- attr(result, "status")
  require_true(is.null(status) || status == 0L,
               program, " failed: ", paste(result, collapse = "\n"))
  result
}

sha256 <- function(paths) {
  invisible(lapply(paths, regular_file))
  program <- if (nzchar(Sys.which("sha256sum"))) "sha256sum" else "shasum"
  args <- c(if (program == "shasum") c("-a", "256"), "--", shQuote(paths))
  result <- checked_command(program, args)
  require_true(length(result) == length(paths) &&
                 all(grepl("^[0-9a-f]{64}[[:space:]]", result)), "Invalid SHA-256 output.")
  substring(result, 1L, 64L)
}

check_single_links <- function(paths) {
  args <- if (Sys.info()[["sysname"]] == "Darwin") c("-f", "%l") else c("-c", "%h")
  counts <- checked_command("stat", c(args, shQuote(paths)))
  require_true(length(counts) == length(paths) && all(counts == "1"),
               "Native files must be ordinary files with one link.")
}

read_csv <- function(path) {
  regular_file(path)
  utils::read.csv(path, check.names = FALSE, colClasses = "character", na.strings = NULL)
}

read_sections <- function(path) {
  regular_file(path)
  lines <- readLines(path, warn = FALSE)
  headers <- which(grepl("^[[:space:]]*#", lines))
  labels <- trimws(sub("^[[:space:]]*#[[:space:]]*", "", lines[headers]))
  function(label, rows = 1L, columns = 1L) {
    index <- which(labels == label)
    require_true(length(index) == 1L, path, ": expected one section: ", label)
    first <- headers[index] + 1L
    last <- if (index < length(headers)) headers[index + 1L] - 1L else length(lines)
    require_true(first <= last, path, ": empty section: ", label)
    text <- trimws(lines[seq.int(first, last)])
    text <- text[nzchar(text)]
    tokens <- strsplit(text, "[[:space:]]+")
    require_true(length(text) == rows && all(lengths(tokens) == columns),
                 path, ": invalid row/column count for ", label)
    values <- suppressWarnings(as.numeric(unlist(tokens, use.names = FALSE)))
    require_true(length(values) == rows * columns && all(is.finite(values)),
                 path, ": non-finite or non-numeric values for ", label)
    matrix(values, nrow = rows, ncol = columns, byrow = TRUE)
  }
}


safe_paths <- function(x) {
  is.character(x) && length(x) > 0L && all(nzchar(x)) && !any(grepl("^/|[\\\\[:cntrl:]]", x)) &&
    all(vapply(strsplit(x, "/", fixed = TRUE), function(p) all(!p %in% c("", ".", "..")), logical(1)))
}
positive <- function(x, label) {
  n <- suppressWarnings(as.numeric(x))
  require_true(length(n) == length(x) && length(n) > 0L && all(is.finite(n) & n > 0), "Invalid positive values: ", label)
  n
}
par_values <- function(path) {
  s <- read_sections(path)
  n <- c(objective = as.numeric(s("Objective function value")), parameters = as.numeric(s("The number of parameters")))
  require_true(is.finite(n[["objective"]]) && n[["parameters"]] > 0 && n[["parameters"]] == as.integer(n[["parameters"]]), "Invalid PAR objective/parameter count.")
  n
}
rep_values <- function(path) {
  s <- read_sections(path)
  dims <- vapply(dimension_labels, function(label) as.numeric(s(label)), numeric(1))
  require_true(all(is.finite(dims) & dims > 0 & dims == as.integer(dims)), "Invalid REP dimensions.")
  require_true(dims[[1L]] <= 2000 && dims[[3L]] <= 100 && dims[[6L]] <= 12 && dims[[1L]] %% dims[[6L]] == 0, "Unsupported/incomplete REP time grid.")
  values <- setNames(as.list(dims), dimension_labels)
  for (label in central_labels[!central_labels %in% dimension_labels]) {
    shape <- if (label %in% c("Adult biomass", "Adult biomass in absence of fishing")) dims[c(1L, 3L)] else c(1L, 1L)
    values[[label]] <- s(label, shape[[1L]], shape[[2L]])
    require_true(all(values[[label]] > 0), "Non-positive central REP: ", label)
  }
  list(dimensions = dims, values = values)
}
check_dimensions <- function(rep, row) {
  fields <- c("periods", "year1", "regions", "species", "ages", "seasons")
  require_true(identical(unname(rep$dimensions), positive(unlist(row[fields], use.names = FALSE), "model dimensions")), "Native dimensions differ from the source case.")
}
compare_rep <- function(actual, reference, row) {
  a <- rep_values(actual); b <- rep_values(reference)
  check_dimensions(a, row); check_dimensions(b, row)
  differences <- vapply(central_labels, function(label) {
    x <- a$values[[label]]; y <- b$values[[label]]
    require_true(identical(dim(x), dim(y)) && length(x) == length(y) && all(abs(x-y) <= 1e-10*pmax(1,abs(y))), "Central REP differs: ", label)
    max(abs(x-y))
  }, numeric(1))
  list(rep = a, max_abs_diff = max(differences))
}
annual_values <- function(rep, model) {
  d <- rep$dimensions; q <- as.integer(d[[6L]])
  annual <- function(x) colMeans(matrix(rowSums(x), nrow = q))/1000
  sb <- annual(rep$values[["Adult biomass"]]); sb0 <- annual(rep$values[["Adult biomass in absence of fishing"]])
  data.frame(key = model, year = seq.int(d[[2L]], length.out = length(sb)), spawning_potential = sb,
             spawning_potential_nofish = sb0, depletion = sb/sb0)
}
compare_annual <- function(rep, root, row) {
  require_true(row$annual_policy %in% c("quarterly_biomass", "source-checked-quarterly-region-sum"), "Unknown source-checked annual policy.")
  reference <- read_csv(file.path(root, "reference", "annual.csv"))
  require_true(all(c("key","year","spawning_potential","spawning_potential_nofish","depletion") %in% names(reference)), "Annual reference columns differ.")
  reference <- reference[reference$key == row$model, , drop = FALSE]
  actual <- annual_values(rep, row$model)
  require_true(nrow(reference) == nrow(actual) && identical(as.numeric(reference$year), as.numeric(actual$year)), "Annual reference model/years differ.")
  maximum <- 0
  for (label in c("spawning_potential","spawning_potential_nofish","depletion")) {
    expected <- positive(reference[[label]], label)
    require_true(all(abs(actual[[label]]-expected) <= 1e-10*pmax(1,abs(expected))), "Native annual values differ: ", label)
    maximum <- max(maximum, abs(actual[[label]]-expected))
  }
  list(rows = nrow(actual), max_abs_diff = maximum)
}
native_log <- function(path, parameters) {
  lines <- readLines(path, warn = FALSE)
  limits <- grep("^[[:space:]]*optfile\\.cpp[[:space:]]+", lines, value = TRUE)
  observed <- 0L
  for (line in limits) {
    values <- strsplit(trimws(sub("^[[:space:]]*optfile\\.cpp[[:space:]]+", "", line)), "[[:space:]]+")[[1L]]
    require_true(length(values) >= 3L && all(grepl("^[-+]?[0-9]+$",values[1:3])), "Malformed native control.")
    if (identical(as.numeric(values[1:2]), c(1,1))) {
      require_true(as.numeric(values[3L]) == 1, "Native ceiling differs from one."); observed <- observed+1L
    }
  }
  counters <- lines[grepl("variables;", lines, fixed=TRUE) & grepl("function[[:space:]]+evaluation",lines)]
  pattern <- "^[[:space:]]*([0-9]+)[[:space:]]+variables;[[:space:]]+iteration[[:space:]]+([0-9]+);[[:space:]]+function[[:space:]]+evaluation[[:space:]]+([0-9]+)[[:space:]]*$"
  for (line in counters) {
    match <- regmatches(line,regexec(pattern,line))[[1L]]
    require_true(length(match)==4L && identical(as.numeric(match[2:4]), c(parameters,0,0)), "Native parameter/iteration/function counter differs.")
  }
  require_true(observed>0 && length(counters)>0, "Native ceiling/zero-counter evidence absent.")
  objectives <- grep("^[[:space:]]*Total func[[:space:]]+[^[:space:]]+[[:space:]]*$",lines,value=TRUE)
  require_true(length(objectives)>0, "Native objective absent.")
  objective <- suppressWarnings(as.numeric(trimws(sub("^[[:space:]]*Total func[[:space:]]+", "", objectives[1L]))))
  require_true(length(objective)==1L && is.finite(objective), "Non-finite native objective.")
  list(objective=objective, control_records=observed, counter_records=length(counters))
}
check_contents <- function(root) {
  lines <- readLines(file.path(root,"CONTENTS.sha256"),warn=FALSE)
  require_true(length(lines)>0L && all(grepl("^[0-9a-f]{64}  [A-Za-z0-9._-]+$",lines)), "Invalid package ledger.")
  names <- substring(lines,67L)
  require_true(!anyDuplicated(names) && setequal(names,c("Makefile","README.md","run-final.R","models.csv","FILES.csv","native.tar.xz","source-policy.json")), "Incomplete package ledger.")
  require_true(identical(sha256(file.path(root,names)),substring(lines,1L,64L)), "Package bytes changed.")
}
read_inventory <- function(root) {
  check_contents(root)
  models <- read_csv(file.path(root,"models.csv")); files <- read_csv(file.path(root,"FILES.csv"))
  columns <- c("model","objective","parameters","source_par_sha256","engine","engine_sha256","engine_bytes","inputs_count","validation_mode","annual_policy","reference_rep_sha256","source_whole_rep_sha256","series_sha256","refit_supported","refit_model_id","refit_note","periods","year1","regions","species","ages","seasons")
  require_true(identical(names(models),columns) && nrow(models)==length(expected_models) && !anyDuplicated(models$model) && setequal(models$model,expected_models), "Saved model roster/schema differs.")
  require_true(all(models$validation_mode %in% c("reference-rep","annual-series")) && all(models$refit_supported %in% c("yes","no")), "Unknown model policy.")
  require_true(identical(names(files),c("path","bytes","sha256","mode")) && safe_paths(files$path) && !anyDuplicated(files$path), "Invalid native file index.")
  require_true(all(grepl("^[0-9]+$",files$bytes)) && all(grepl("^[0-9]+$",files$mode)) && all(as.numeric(files$mode)<=511) && all(grepl("^[0-9a-f]{64}$",files$sha256)), "Invalid native file metadata.")
  require_true(all(grepl("^[0-9a-f]{64}$",models$source_par_sha256)) && all(grepl("^[0-9a-f]{64}$",models$reference_rep_sha256)) && all(grepl("^[0-9a-f]{64}$",models$source_whole_rep_sha256)), "Invalid source scientific hashes.")
  for (i in seq_len(nrow(models))) {
    row <- models[i,]; prefix <- paste0("models/",row$model,"/")
    paths <- files$path[startsWith(files$path,prefix)]
    inputs <- c("bet.frq","bet.ini","bet.tag","bet.age_length","mfcl.cfg",if(row$inputs_count=="6")"bet.reg_scaling")
    require_true(row$inputs_count %in% c("5","6") && all(paste0(prefix,c(inputs,"final.par","doitall.sh","reference.rep")) %in% paths), "Incomplete native case: ",row$model)
    require_true(files$sha256[match(paste0(prefix,"final.par"),files$path)]==row$source_par_sha256 && files$sha256[match(paste0(prefix,"reference.rep"),files$path)]==row$reference_rep_sha256, "Model/file scientific binding differs.")
    require_true(row$engine %in% files$path && files$sha256[match(row$engine,files$path)]==row$engine_sha256 && files$bytes[match(row$engine,files$path)]==row$engine_bytes && files$mode[match(row$engine,files$path)]=="493", "Case engine binding differs.")
    if(family=="stepwise" && row$model=="01-Diag2023") require_true(row$engine_sha256=="b872c4d049a305d6d89600aea50ffb5d714ab1e5083c44cc712464612dd66aa2" && row$engine_bytes=="9732024", "Step01 needs its preserved engine.")
    else require_true(row$engine_sha256=="f5bc1e232a86e51f920bce7271d8e0930d0b160e4d18dc46de44078f0fa24cd0", "Native engine differs.")
  }
  list(models=models,files=files)
}
check_files <- function(root, files) {
  paths <- file.path(root,files$path)
  for (path in paths) {
    current <- dirname(path)
    while(nchar(current)>=nchar(root)) { directory(current); if(current==root)break;current<-dirname(current) }
  }
  info <- file.info(paths)
  invisible(lapply(paths,regular_file));check_single_links(paths)
  require_true(identical(as.numeric(info$size),as.numeric(files$bytes)) && identical(as.integer(info$mode),as.integer(files$mode)) && identical(sha256(paths),files$sha256), "Saved file bytes/modes changed.")
}
check_payload_tree <- function(root, files) {
  paths <- unlist(lapply(c("models","engines","reference"),function(folder) {
    base <- file.path(root,folder)
    if(!dir.exists(base))return(character())
    directory(base);list.files(base,all.files=TRUE,recursive=TRUE,include.dirs=TRUE,no..=TRUE,full.names=TRUE)
  }),use.names=FALSE)
  regular <- character()
  for(path in paths) {
    link<-Sys.readlink(path);require_true(is.na(link)||!nzchar(link),"Linked native path refused.")
    if(!file.info(path)$isdir)regular<-c(regular,path)
  }
  names<-substring(regular,nchar(root)+2L)
  require_true(setequal(names,files$path),"Extracted native roster differs.")
  check_files(root,files)
}
unpack_models <- function(root, inventory) {
  if(dir.exists(file.path(root,"models"))) {check_payload_tree(root,inventory$files);return(invisible(NULL))}
  archive<-file.path(root,"native.tar.xz")
  names<-checked_command("tar",c("-tf",shQuote(archive)))
  types<-checked_command("tar",c("-tvf",shQuote(archive)))
  require_true(length(names)==nrow(inventory$files) && !anyDuplicated(names) && safe_paths(names) && setequal(names,inventory$files$path) && length(types)==length(names) && all(startsWith(types,"-")),"Native archive roster/types differ.")
  stage<-tempfile(".unpack-",tmpdir=root);require_true(dir.create(stage,mode="0700"),"Cannot stage native files.")
  on.exit(unlink(stage,recursive=TRUE),add=TRUE)
  checked_command("tar",c("-xpf",shQuote(archive),"-C",shQuote(stage)))
  check_payload_tree(stage,inventory$files)
  for(name in c("models","engines","reference")) if(dir.exists(file.path(stage,name))) {
    target<-file.path(root,name);require_true(!exists_path(target)&&file.rename(file.path(stage,name),target),"Native destination appeared.")
  }
}
check_model <- function(root,row,inventory) {
  folder<-file.path(root,"models",row$model)
  p<-par_values(file.path(folder,"final.par"))
  require_true(abs(p[["objective"]]-as.numeric(row$objective))<=1e-6 && p[["parameters"]]==as.numeric(row$parameters),"Saved PAR index differs.")
  reference<-rep_values(file.path(folder,"reference.rep"));check_dimensions(reference,row)
  if(nzchar(row$annual_policy)) {
    require_true(sha256(file.path(root,"reference","annual.csv"))==row$series_sha256,"Annual source checksum differs.")
    compare_annual(reference,root,row)
  }
  invisible(p)
}
fresh_output <- function(root,raw) {
  require_true(length(raw)==1L&&nzchar(raw)&&startsWith(raw,"/")&&!exists_path(raw),"Set OUT to an absolute fresh directory.")
  parent<-normalizePath(dirname(raw),mustWork=TRUE);directory(parent)
  name<-basename(raw);require_true(!name%in%c(".","..")&&nzchar(name),"Invalid OUT name.")
  output<-file.path(parent,name)
  require_true(output!=root&&!startsWith(output,paste0(root,"/")),"OUT must be outside the package.")
  if(!is.null(reader_checkout))require_true(output!=reader_checkout&&(!startsWith(output,paste0(reader_checkout,"/"))||startsWith(output,paste0(reader_checkout,"/outputs/"))),"OUT inside the checkout must be beneath outputs/.")
  output
}
prepare_model <- function(root,inventory,model,raw) {
  index<-match(model,inventory$models$model);require_true(!is.na(index),"Unknown saved case.")
  out<-fresh_output(root,raw);unpack_models(root,inventory)
  row<-inventory$models[index,,drop=FALSE];check_model(root,row,inventory)
  selected<-inventory$files[startsWith(inventory$files$path,paste0("models/",model,"/")),,drop=FALSE]
  check_files(root,selected);require_true(dir.create(out,mode="0700"),"Cannot create OUT.")
  for(i in seq_len(nrow(selected))) {
    name<-substring(selected$path[i],nchar(paste0("models/",model,"/"))+1L);target<-file.path(out,name)
    if(!dir.exists(dirname(target)))require_true(dir.create(dirname(target),recursive=TRUE,mode="0700"),"Cannot stage nested inputs.")
    require_true(file.copy(file.path(root,selected$path[i]),target,copy.mode=TRUE,overwrite=FALSE),"Cannot copy saved file.")
    require_true(Sys.chmod(target,as.octmode(as.integer(selected$mode[i])),use_umask=FALSE),"Cannot retain saved mode.")
  }
  engine<-file.path(out,"mfclo64");require_true(file.copy(file.path(root,row$engine),engine,copy.mode=TRUE,overwrite=FALSE),"Cannot copy engine.")
  require_true(Sys.chmod(engine,"0755",use_umask=FALSE)&&sha256(engine)==row$engine_sha256,"Copied engine differs.")
  selected$path<-substring(selected$path,nchar(paste0("models/",model,"/"))+1L);check_files(out,selected)
  list(output=out,row=row,files=selected)
}
require_linux <- function() {
  require_true(Sys.info()[["sysname"]]=="Linux"&&tolower(Sys.info()[["machine"]])%in%c("x86_64","amd64"),"MFCL execution requires Linux x86-64.")
}
evaluate_model <- function(root,prepared) {
  out<-prepared$output;row<-prepared$row
  saved<-par_values(file.path(out,"final.par"));before<-sha256(file.path(out,"final.par"))
  require_true(file.copy(file.path(out,"final.par"),file.path(out,"input.par"),overwrite=FALSE,copy.mode=TRUE),"Cannot stage evaluation PAR.")
  writeLines(controls,file.path(out,"evaluation-controls.txt"),useBytes=TRUE)
  old<-setwd(out);on.exit(setwd(old),add=TRUE)
  status<-suppressWarnings(system2("./mfclo64",c("bet.frq","input.par","evaluated.par","-file","-"),stdin="evaluation-controls.txt",stdout="mfcl-native.log",stderr="mfcl-native.log",timeout=1200))
  require_true(status%in%c(0L,3L),"Native evaluation failed; inspect mfcl-native.log (exit ",status,").")
  check_files(out,prepared$files)
  require_true(identical(sha256(c("final.par","input.par")),rep(before,2L))&&sha256("mfclo64")==row$engine_sha256,"Native inputs/PAR/engine changed.")
  observed<-par_values("evaluated.par");logged<-native_log("mfcl-native.log",saved[["parameters"]])
  require_true(observed[["parameters"]]==saved[["parameters"]],"Native parameter count differs.")
  difference<-max(abs(c(observed[["objective"]],logged$objective)-saved[["objective"]]))
  require_true(difference<=1e-6,"Saved objective differs by more than 1e-6.")
  report<-rep_values("plot-evaluated.par.rep");check_dimensions(report,row)
  central<-if(row$validation_mode=="reference-rep")compare_rep("plot-evaluated.par.rep","reference.rep",row)$max_abs_diff else NA_real_
  require_true(row$validation_mode=="reference-rep"||nzchar(row$annual_policy),"Annual comparison policy absent.")
  annual<-if(nzchar(row$annual_policy))compare_annual(report,root,row) else list(rows=0L,max_abs_diff=NA_real_)
  write.csv(annual_values(report,row$model),"central-results.csv",row.names=FALSE)
  receipt<-data.frame(model=row$model,mode="outputs-only",function_evaluation_ceiling=1L,iteration=0L,function_counter=0L,parameters=observed[["parameters"]],native_exit_code=status,
    saved_objective=saved[["objective"]],evaluated_objective=observed[["objective"]],logged_objective=logged$objective,objective_max_abs_diff=difference,central_rep_max_abs_diff=central,
    annual_rows=annual$rows,annual_max_abs_diff=annual$max_abs_diff,engine_sha256=row$engine_sha256,input_par_sha256=before,source_whole_rep_sha256=row$source_whole_rep_sha256,native_inputs_unchanged=TRUE)
  write.csv(receipt,"evaluation-check.csv",row.names=FALSE,na="")
  cat(row$model,": saved native outputs verified.\n",sep="")
}
refit_model <- function(prepared) {
  row<-prepared$row;require_true(row$refit_supported=="yes","Full-refit dependencies unresolved: ",row$refit_note)
  old<-setwd(prepared$output);on.exit(setwd(old),add=TRUE)
  env<-c("PROGRAM_PATH=./mfclo64",paste0("PATH=",shQuote(paste0(prepared$output,":",Sys.getenv("PATH")))),"BET_PHASE10_11_CONVERGENCE=-4")
  if(nzchar(row$refit_model_id))env<-c(env,paste0("MODEL_ID=",row$refit_model_id))
  status<-suppressWarnings(system2("sh","./doitall.sh",env=env,stdout="mfcl-refit.log",stderr="mfcl-refit.log"))
  require_true(status==0L,"Original fitting script failed; inspect mfcl-refit.log.")
  cat("Original full-fit script completed. Inspect the new PARs in ",prepared$output,".\n",sep="")
}
package_root <- function(script) {
  base<-dirname(script)
  if(file.exists(file.path(base,"models.csv")))return(base)
  archive<-file.path(base,"standalone.zip");regular_file(archive)
  sums<-readLines(file.path(base,"standalone.sha256"),warn=FALSE)
  require_true(length(sums)==1L&&grepl("^[0-9a-f]{64}  standalone\\.zip$",sums)&&sha256(archive)==substr(sums,1L,64L),"Standalone ZIP checksum differs.")
  listing<-utils::unzip(archive,list=TRUE)
  expected<-paste0("bet-2026-",family,"-standalone/",c("Makefile","README.md","run-final.R","models.csv","FILES.csv","native.tar.xz","source-policy.json","CONTENTS.sha256"))
  require_true(nrow(listing)==length(expected)&&!anyDuplicated(listing$Name)&&setequal(listing$Name,expected),"Standalone ZIP roster differs.")
  target<-tempfile(paste0("bet-",family,"-"));require_true(dir.create(target,mode="0700"),"Cannot stage package.")
  utils::unzip(archive,exdir=target)
  file.path(target,paste0("bet-2026-",family,"-standalone"))
}
run_final <- function(args=commandArgs(trailingOnly=TRUE)) {
  script<-grep("^--file=",commandArgs(),value=TRUE);require_true(length(script)==1L,"Use Rscript run-final.R.")
  source<-normalizePath(sub("^--file=","",script),mustWork=TRUE)
  candidate<-dirname(source)
  while(candidate!=dirname(candidate)) {
    if(exists_path(file.path(candidate,".git"))) {reader_checkout<<-candidate;break}
    candidate<-dirname(candidate)
  }
  root<-package_root(source)
  require_true(length(args)>=1L,"Use list|verify|prepare|restore|rerun|refit [CASE] [absolute fresh OUT].")
  action<-args[1L];require_true(action%in%c("list","verify","unpack","prepare","restore","rerun","refit"),"Unknown action.")
  inventory<-read_inventory(root)
  if(action=="list") {require_true(length(args)==1L,"list needs no case.");cat(paste(sort(inventory$models$model),collapse="\n"),"\n",sep="");return(invisible(NULL))}
  if(action%in%c("verify","unpack")) {
    require_true(length(args)==1L,"No case required.");unpack_models(root,inventory)
    if(action=="verify")for(i in seq_len(nrow(inventory$models)))check_model(root,inventory$models[i,,drop=FALSE],inventory)
    cat("Verified preserved native files for ",nrow(inventory$models)," cases.\n",sep="");return(invisible(NULL))
  }
  require_true(length(args)==3L,"Use ACTION CASE /absolute/fresh/OUT.")
  if(action%in%c("rerun","refit"))require_linux()
  if(args[2L]=="all") {
    require_true(action!="refit","Choose one case for a full fit.")
    out<-fresh_output(root,args[3L]);require_true(dir.create(out,mode="0700"),"Cannot create collection OUT.")
    for(model in sort(inventory$models$model)) {
      prepared<-prepare_model(root,inventory,model,file.path(out,model));if(action=="rerun")evaluate_model(root,prepared)
    }
  } else {
    prepared<-prepare_model(root,inventory,args[2L],args[3L])
    if(action=="rerun")evaluate_model(root,prepared)
    else if(action=="refit")refit_model(prepared)
    else cat("Prepared exact native files: ",prepared$output,"\n",sep="")
  }
}
if(sys.nframe()==0L)tryCatch(run_final(),error=function(e){message(conditionMessage(e));quit(status=1L)})
