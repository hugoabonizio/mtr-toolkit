motc.importance.tech <- "rf_imp"

dir.create(paste0(output.dir.motc, "/prediction_logs/",tech), showWarnings = FALSE, recursive = TRUE)
dir.create(paste0(output.dir.motc, "/out_imp_assessment/",tech), showWarnings = FALSE, recursive = TRUE)
dir.create(paste0(output.dir.motc, "/raw_logs/",tech), showWarnings = FALSE, recursive = TRUE)

hoeffdings.bound <- function(observations, range = 100, confidence = 0.05) {
	return(sqrt((range*log(1/confidence))/(2*observations)))
}

getChainingTree <- function(imp, tar, hb, max.level) {
	chain <- new.env()
	chain$tree <- data.table(orig=numeric(0), dest=numeric(0))
	chain$hash <- list()
	chain$imp <- imp
	chain$hb <- hb
	chain$max.level <- max.level
	chain$leafs <- list()

	letitchaining <- function(target = tar, node.id = 1, level = 1) {
		chain$hash[node.id] <- target
		chain$leafs[node.id] <- FALSE

		if(level < chain$max.level) {
			max.i <- which.max(chain$imp[target,])
			# filter relevant targets
			if(is.null(chain$hb))
				rel.idx <- which(chain$imp[target,] > 0)
			else
				rel.idx <- which(chain$imp[target,] >= chain$imp[target, max.i] - chain$hb)
			rel <- colnames(chain$imp)[rel.idx]

			next.t <- node.id + 1
			for(r in rel) {
				chain$tree <- rbindlist(list(chain$tree, list(orig=node.id, dest=next.t)))
				next.t <- letitchaining(r, next.t, level+1)
			}
			return(next.t)
		} else {
			chain$tree <- rbindlist(list(chain$tree, list(orig=node.id, dest=NA)))
			chain$leafs[node.id] <- TRUE
			return(node.id + 1)
		}
	}
	letitchaining()
	return(list(tree = chain$tree, hash = as.character(chain$hash), leafs = as.logical(chain$leafs), depth = chain$max.level))
}

buildChainTree <- function(orc, x.train, y.train, x.test, tech, targets) {
	root.node <- 1
	bct <- new.env()
	len.preds <- length(unique(orc$hash[orc$leafs])) + length(orc$hash[!orc$leafs])

	bct$pred.tr <- data.table(matrix(nrow=nrow(x.train), ncol=len.preds))
	bct$pred.ts <- data.table(matrix(nrow=nrow(x.test), ncol=len.preds))
	bct$xtr <- x.train
	bct$xts <- x.test
	bct$ytr <- y.train
	bct$c.cont <- 1L

	chainTravel <- function(t.node = 1, f.node = 0) {
		edg <- which(orc$tree$orig == t.node)

		# Leaf node
		if(length(edg) == 1 && is.na(orc$tree[edg,dest])) {
			# Verifies if the leaf node's ST model was already trained
			if(!(paste0("leaf.", orc$hash[t.node]) %in% names(bct$pred.ts))) {
				regressor <- train_(bct$xtr, bct$ytr[[orc$hash[t.node]]], tech, targets)
				set(bct$pred.tr, NULL, bct$c.cont, predict_(regressor, bct$xtr, tech, targets))
				set(bct$pred.ts, NULL, bct$c.cont, predict_(regressor, bct$xts, tech, targets))

				if(f.node == 0) {
					names(bct$pred.tr)[bct$c.cont] <- paste0("0.", orc$hash[t.node])
					names(bct$pred.ts)[bct$c.cont] <- paste0("0.", orc$hash[t.node])
				} else {
					names(bct$pred.tr)[bct$c.cont] <- paste0("leaf.", orc$hash[t.node])
					names(bct$pred.ts)[bct$c.cont] <- paste0("leaf.", orc$hash[t.node])
				}

				bct$c.cont <- bct$c.cont + 1L
			}

		} else {
			for(e in edg) {
				chainTravel(orc$tree[e,dest], t.node)
			}

			leaf.sons <- orc$leafs[orc$tree[edg,dest]]
			sons.names <- orc$hash[orc$tree[edg,dest]]
			aug.names <- paste(t.node, sons.names, sep = ".")
			aug.names[leaf.sons] <- paste0("leaf.", sons.names[leaf.sons])

			# Make augmented sets
			set(bct$xtr, NULL, orc$hash[orc$tree[edg,dest]], bct$pred.tr[, aug.names, with = F])
			set(bct$xts, NULL, orc$hash[orc$tree[edg,dest]], bct$pred.ts[, aug.names, with = F])

			regressor <- train_(bct$xtr, bct$ytr[[orc$hash[t.node]]], tech, targets)

			# Save predictions
			set(bct$pred.tr, NULL, bct$c.cont, predict_(regressor, bct$xtr, tech, targets))
			set(bct$pred.ts, NULL, bct$c.cont, predict_(regressor, bct$xts, tech, targets))
			# Set appropriate names
			names(bct$pred.tr)[bct$c.cont] <- paste(f.node, orc$hash[t.node], sep = ".")
			names(bct$pred.ts)[bct$c.cont] <- paste(f.node, orc$hash[t.node], sep = ".")

			bct$c.cont <- bct$c.cont + 1L

			# Remove augmented features
			bct$xtr[, orc$hash[orc$tree[edg,dest]] := NULL]
			bct$xts[, orc$hash[orc$tree[edg,dest]] := NULL]
		}
		return(NULL)
	}

	chainTravel()

	return(list(tr = bct$pred.tr, ts = bct$pred.ts))
}

getPrintableChainTree <- function(orc) {
	len.tree <- nrow(orc$tree)
	prtbl <- new.env()
	prtbl$tree <- data.table(orig=character(len.tree), dest=character(len.tree))

	sapply(1:len.tree, function(idx, ptree, tree, hash) {
		prtbl$tree[idx,1] <- paste(tree[idx,orig], hash[tree[idx,orig]], sep = ".")
		if(!is.na(tree[idx,dest]))
			prtbl$tree[idx,2] <- paste(tree[idx,dest], hash[tree[idx,dest]], sep = ".")
	}, tree = orc$tree, hash = orc$hash)

	return(prtbl$tree)
}

targets <- list()
maxs <- list()
mins <- list()

for(i in 1:length(bases)) {
	set.seed(exp.seed)
	dataset <- read.csv(paste0(datasets.folder, "/", bases[i], ".csv"))
	dataset <- remove.unique(dataset)

	targets[[i]] <- colnames(dataset)[(ncol(dataset)-n.targets[i]+1):ncol(dataset)]

	dataset <- dataset[sample(nrow(dataset)),]
	sample.names <- rownames(dataset)

	#Center and Scaling
	dataset <- as.data.table(dataset)
	invisible(dataset[, names(dataset) := lapply(.SD, as.numeric)])

	maxs[[i]] <- as.numeric(dataset[, lapply(.SD, max)])
	names(maxs[[i]]) <- colnames(dataset)
	mins[[i]] <- as.numeric(dataset[, lapply(.SD, min)])
	names(mins[[i]]) <- colnames(dataset)
	dataset <- as.data.table(scale(dataset, center = mins[[i]], scale = maxs[[i]] - mins[[i]]))

	len.fold <- round(nrow(dataset)/folds.num)

	###################################Use a testing set#####################################
	if(length(bases.teste) > 0 && folds.num == 1) {
		dataset.teste <- read.csv(paste0(datasets.folder, "/", bases.teste[i], ".csv"))
		dataset.teste <- as.data.table(dataset.teste)
		invisible(dataset.teste[, names(dataset.teste) := lapply(.SD, as.numeric)])

		dataset.teste <- as.data.table(scale(dataset.teste, center = mins[[i]], scale = maxs[[i]] - mins[[i]]))
		init.bound <- nrow(dataset) + 1

		dataset <- rbindlist(list(dataset, dataset.teste))
		sample.names <- c(sample.names, rownames(dataset.teste))
	}
	#########################################################################################

	x <- dataset[, !targets[[i]], with = FALSE]
	y <- dataset[, targets[[i]], with = FALSE]

	if(showProgress){}else{print(bases[i])}

	# Cross validation
	for(k in 1:folds.num) {
		if(showProgress){}else{print(paste0("Fold ", k))}

		if(folds.num == 1) {
			if(length(bases.teste) > 0) {
				train.idx <- 1:(init.bound-1)
				test.idx <- init.bound:nrow(dataset)
			} else {
				test.idx <- as.numeric(rownames(dataset))
				train.idx <- test.idx
			}
		} else {
			test.idx <- ((k-1)*len.fold + 1):(ifelse(k==folds.num, nrow(dataset), k*len.fold))
			train.idx <- setdiff(1:nrow(dataset), test.idx)
		}

		x.train <- x[train.idx]
		y.train <- y[train.idx]

		x.test <- x[test.idx]
		y.test <- y[test.idx]

		###########################################Importance calc##############################################
		timportance <- getTargetImportance(y.train, motc.importance.tech)
		write.csv(timportance, paste0(output.dir.motc, "/out_imp_assessment/", tech, "/", bases[i], "_importance_fold", formatC(k, width=2, flag="0"), ".csv"))
		########################################################################################################

		t.names <- c(targets[[i]], paste0(targets[[i]], ".pred"))
		prediction.log <- as.data.table(setNames(replicate(length(t.names),numeric(nrow(x.test)), simplify = F), t.names))
		t.cont <- 1

		for(t in targets[[i]]) {
				orc <- getChainingTree(timportance, t, hoeffdings.bound(nrow(x.train), range =
							ifelse(motc.importance.tech == "rf_imp", 100, 1)), round(2*log2(n.targets[i])))
				predictions <- buildChainTree(orc, x.train, y.train, x.test, tech, targets)

				write.csv(data.frame(id=sample.names[train.idx], predictions$tr, check.names = F), paste0(output.dir.motc, "/raw_logs/",tech,"/raw_MOTC_training_", bases[i], "_fold", formatC(k, width=2, flag="0"), "_T", formatC(t.cont, width=2, flag="0"), ".csv"), row.names = FALSE)
				write.csv(data.frame(id=sample.names[test.idx], predictions$ts, check.names = F), paste0(output.dir.motc, "/raw_logs/",tech,"/raw_MOTC_testing_", bases[i], "_fold", formatC(k, width=2, flag="0"), "_T", formatC(t.cont, width=2, flag="0"), ".csv"), row.names = FALSE)

				set(prediction.log, NULL, t, y.test[[t]])
				set(prediction.log, NULL, paste0(t, ".pred"), predictions$ts[[paste0("0.",t)]])

				write.csv(getPrintableChainTree(orc), paste0(output.dir.motc, "/out_imp_assessment/",tech,"/", bases[i], "_chain_tree_fold", formatC(k, width=2, flag="0"), "_T", formatC(t.cont, width=2, flag="0"), ".csv"), row.names = FALSE)

			t.cont <- t.cont + 1
			}

		write.csv(data.frame(id=sample.names[test.idx], prediction.log, check.names = F), paste0(output.dir.motc, "/prediction_logs/",tech,"/predictions_MOTC_", bases[i], paste0("_fold", formatC(k, width=2, flag="0")), ".csv"), row.names = FALSE)
	}
}

#Performance metrics
actual.folder <- getwd()
setwd(paste0(output.dir.motc, "/prediction_logs"))
i <<- 1

lapply(bases, function(b) {
	names.perf.log <- c("aCC", "ARE", "MSE", "aRMSE", "aRRMSE", paste0("R2.", targets[[i]]), paste0("RMSE.", targets[[i]]))
	performance.log <<- data.frame(algorithm=character(0), as.data.frame(setNames(replicate(length(names.perf.log),numeric(0),
												simplify = F), names.perf.log)), stringsAsFactors = FALSE)

	folds.log <<- as.data.frame(setNames(replicate(length(names.perf.log),numeric(0),
										simplify = F), names.perf.log), stringsAsFactors = FALSE)
	lapply(1:folds.num, function(k) {
		log <- read.csv(paste0(getwd(),"/", tech, "/predictions_MOTC_", b, paste0("_fold", formatC(k, width=2, flag="0")),".csv"), header=TRUE)
		folds.log[nrow(folds.log)+1, "aCC"] <<- aCC(log, targets[[i]])
		folds.log[nrow(folds.log), "ARE"] <<- ARE(log, targets[[i]])
		folds.log[nrow(folds.log), "MSE"] <<- MSE(log, targets[[i]])
		folds.log[nrow(folds.log), "aRMSE"] <<- aRMSE(log, targets[[i]])
		folds.log[nrow(folds.log), "aRRMSE"] <<- aRRMSE(log, targets[[i]])

		# targets
		for(t in targets[[i]]) {
			folds.log[nrow(folds.log), paste0("R2.", t)] <<- summary(lm(log[,t] ~ log[, paste0(t, ".pred")]))$r.squared

			r <- (maxs[[i]][t]-mins[[i]][t])*log[,t] + mins[[i]][t]
			p <- (maxs[[i]][t]-mins[[i]][t])*log[,paste0(t, ".pred")] + mins[[i]][t]

			folds.log[nrow(folds.log), paste0("RMSE.", t)] <<- RMSE(r, p)
		}
	})
	performance.log[nrow(performance.log)+1, 1] <<- tech
	performance.log[nrow(performance.log), -1] <<- colMeans(folds.log)

	write.csv(performance.log, paste0("../performance_MOTC_", tech, "_", b, ".csv"), row.names = FALSE)
	i <<- i + 1
})
setwd(actual.folder)