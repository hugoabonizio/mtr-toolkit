#' Creates Multi-target Regression Trees (MTRT), as in CLUS
#'
#' @param X, Y The input features and target variables respectively
#' @param ftest.signf The signficance level for F-test's stopping criteria (Default = 0.05)
#' @param min.size Minimum size of generated clusteres (Default = 5, as in CLUS)
#' @param max.depth Maximum depth for generated trees (Default = Inf, split are made while it is possible)
#' @return A MTRT model
#' @export
MTRT <- function(X, Y, ftest.signf = 0.05, min.size = 2, max.depth = Inf) {
	nodes <- new.env(parent = emptyenv())
	# Nodes
	nodes$tovisit <- list(NULL)
	# All instances should be evaluated at first
	nodes$tovisit[[1]] <- seq(nrow(X))
	# Nodes ids to linking the tree's nodes
	nodes$ids <- list(NULL)
	# The first id is the root node
	nodes$ids[[1]] <- 1

	# Structure to keep the tree hierarchy
	# Parent, branch = {1:left, 2:right}, level
	nodes$tree <- data.table(N1 = c(NA,NA,1))

	# Structure to save the created nodes and leaves
	nodes$elem <- new.env(parent = emptyenv())

	# Aux variables to efficiently add elements to the 'tovisit' and 'id' queues
	nodes$counter <- 1
	nodes$size <- 1

	addNode2Visit <- function(item, id, parent, pos, level) {
		if(nodes$counter == nodes$size) {
			length(nodes$tovisit) <- length(nodes$ids) <- nodes$size <- 2 * nodes$size
		}

		if(nodes$size == 0)
			nodes$size <- 1

		nodes$counter <- nodes$counter + 1

		nodes$tovisit[[nodes$counter]] <- item
		nodes$ids[[nodes$counter]] <- id

		# Save tree hierarchy
		nodes$tree[, paste0("N", id) := c(parent, pos, level)]

		NULL
	}

	getNode2Visit <- function() {
		idx <- nodes$tovisit[[1]]
		nodes$tovisit[[1]] <- NULL
		this <- nodes$ids[[1]]
		nodes$ids[[1]] <- NULL

		nodes$size <- nodes$size - 1
		nodes$counter <- nodes$counter - 1
		return(list(idx = idx, this = this))
	}

	getNodeInfo <- function(id) {
		nodes$tree[[paste0("N", id)]]
	}

	thereAreNodes2Visit <- function() {
		nodes$counter > 0
	}

	link2Parent <- function(node, parent.id, branch) {
		nodes$parent <- nodes$elem[[as.character(parent.id)]]
		nodes$parent$descendants[[branch]] <- node
		NULL
	}

	build.MTRT.inc <- function() {
		node.id <- 2

		while(thereAreNodes2Visit()) {
			n2v <- getNode2Visit()
			idx <- n2v$idx
			this.id <- n2v$this

			# Retrieves node's information
			info <- getNodeInfo(this.id)
			parent.id <- info[[1]]
			branch <- info[[2]]
			this.level <- info[[3]]

			# Naive stopping criterion
			if(length(idx) <= min.size || this.level > max.depth) {
				n <- new.env(parent = emptyenv())
				n$descendants <- NULL
				if(length(idx) == 1)
					l.pred <- unname(Y[idx,])
				else
					l.pred <- prototype(Y[idx,])

				n$protot <- l.pred
				# n$eval <- function(node) {
				# 	node$protot
				# }
				# Saves node for posterior reference
				nodes$elem[[as.character(this.id)]] <- n

				if(this.id > 1)
					link2Parent(n, parent.id, branch)

				if(thereAreNodes2Visit())
					next
				else
					break
			}

			this.var <- variance(Y[idx,])
			this.prot <- prototype(Y[idx,])

			bests <- X[idx, lapply(.SD, function(attr, T, acvar, acprot) best_split(attr, T, acvar, acprot), T = Y[idx,], acvar = this.var, acprot = this.prot)]

			# Second stopping criteria
			if(all(is.na(bests[1]))) {
				n <- new.env(parent = emptyenv())
				n$descendants <- NULL
				l.pred <- prototype(Y[idx,])

				n$protot <- l.pred
				# n$eval <- function(node) {
				# 	node$protot
				# }
				# Saves node for posterior reference
				nodes$elem[[as.character(this.id)]] <- n

				if(this.id > 1)
					link2Parent(n, parent.id, branch)

				rm(bests)
				if(thereAreNodes2Visit())
					next
				else
					break
			}

			best.s <- which.max(unlist(bests[2], use.names = F))

			n <- new.env(parent = emptyenv())
			n$split.name <- names(bests)[best.s]
			n$split.val <- unlist(bests[1, best.s, with = F], use.names = F)

			# n$eval <- function(new, node) {
			# 	as.numeric(new > node$split.val) + 1
			# }
			n$descendants <- list()
			# TODO categorical features
			length(n$descendants) <- 2

			if(this.id > 1)
				link2Parent(n, parent.id, branch)

			# Saves node for posterior reference
			nodes$elem[[as.character(this.id)]] <- n

			# Induced data partition
			part <- X[idx, best.s, with = FALSE] <= n$split.val

			addNode2Visit(idx[part], node.id, this.id, 1, this.level + 1)
			addNode2Visit(idx[!part], node.id + 1, this.id, 2, this.level + 1)

			node.id <- node.id + 2

			rm(bests)
		}

		root <- nodes$elem[["1"]]
		return(root)
	}

	Y <- as.matrix(Y)
	tree <- build.MTRT.inc()

	targets <- colnames(Y)
	rm(nodes, X, Y)

	retr <- list(tree = unlist(tree, recursive = F), targets = targets, type = "MTRT")
	return(retr)
}

predictMTRT <- function(mtrt, new.data) {
	predictions <- list()
	length(predictions) <- nrow(new.data)

	i <- 1
	apply(new.data, 1, function(dat, predictions) {
		root <- mtrt$tree

		while(TRUE) {
			if(length(root$descendants) == 0) {
				predictions[[i]] <<- root$protot
				break
			} else {
				next.n <- as.numeric(dat[root$split.name] > root$split.val) + 1
				root <- root$descendants[[next.n]]
			}
		}
		i <<- i + 1
	}, predictions = predictions)
	backup <- predictions
	predictions <- as.data.table(matrix(unlist(predictions, use.names = F), ncol = length(mtrt$targets), byrow = TRUE))
	names(predictions) <- mtrt$targets
	# Make some memory free
	rm(backup)
	return(predictions)
}
