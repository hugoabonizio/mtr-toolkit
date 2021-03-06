% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/utilities.R
\name{scaleData}
\alias{scaleData}
\title{Scale the passed data within the range [0,1]. Scaled data is required for use Cluster-based prediction trees.}
\usage{
scaleData(data)
}
\arguments{
\item{data}{The data to be scaled}
}
\value{
A data.table containing the scaled data
}
\description{
Scale the passed data within the range [0,1]. Scaled data is required for use Cluster-based prediction trees.
}
