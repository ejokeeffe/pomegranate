# gmm.pyx: Yet Another Hidden Markov Model library
# Contact: Jacob Schreiber ( jmschreiber91@gmail.com )

cimport cython
from cython.view cimport array as cvarray
from libc.math cimport log as clog, sqrt as csqrt, exp as cexp
import math, random, itertools as it, sys, bisect
import networkx

if sys.version_info[0] > 2:
	# Set up for Python 3
	from functools import reduce
	xrange = range
	izip = zip
else:
	izip = it.izip

import numpy
cimport numpy

cimport distributions
from distributions cimport *

cimport utils
from utils cimport *

cimport base
from base cimport *

# Define some useful constants
DEF NEGINF = float("-inf")
DEF INF = float("inf")
DEF SQRT_2_PI = 2.50662827463

# Useful python-based array-intended operations
def log(value):
	"""
	Return the natural log of the given value, or - infinity if the value is 0.
	Can handle both scalar floats and numpy arrays.
	"""

	if isinstance( value, numpy.ndarray ):
		to_return = numpy.zeros(( value.shape ))
		to_return[ value > 0 ] = numpy.log( value[ value > 0 ] )
		to_return[ value == 0 ] = NEGINF
		return to_return
	return _log( value )
		
def exp(value):
	"""
	Return e^value, or 0 if the value is - infinity.
	"""
	
	return numpy.exp(value)

def log_probability( model, samples ):
	'''
	Return the log probability of samples given a model.
	'''

	return sum( map( model.log_probability, samples ) )

cdef class GaussianMixtureModel( object ):
	"""
	A Gaussian Mixture Model. Currently assumes a diagonal covariance matrix.
	"""

	cdef public list distributions
	cdef public numpy.ndarray weights 

	def __init__( self, distributions, weights=None ):
		"""
		Take in a list of MultivariateDistributions to be optimized.
		"""

		if weights is None:
			# Weight everything 1 if no weights specified
			weights = numpy.ones_like(distributions, dtype=float) / len( distributions )
		else:
			# Force whatever we have to be a Numpy array
			weights = numpy.asarray(weights) / weights.sum()

		self.weights = weights
		self.distributions = distributions

	def log_probability( self, point ):
		"""
		Calculate the probability of a point given the model. The probability
		of a point is the sum of the probabilities of each distribution.
		"""

		return self._log_probability( numpy.array( point ) )

	cdef double _log_probability( self, numpy.ndarray point ):
		"""
		Cython optimized function for calculating log probabilities.
		"""

		cdef n=len(self.distributions), i=0
		cdef double log_probability_sum=NEGINF, log_probability
		cdef Distribution d

		for i in xrange( n ):
			d = self.distributions[i]
			log_probability = d.log_probability( point )
			log_probability_sum = pair_lse( log_probability_sum,
											log_probability )

		return log_probability_sum

	def train( self, items, stop_threshold=0.1, max_iterations=1e8,
		diagonal=False, verbose=False ):
		"""
		Take in a list of data points and their respective weights. These are
		most likely uniformly weighted, but the option exists if you want to
		add a second layer of weights on top of the ones learned in the
		expectation step.
		"""

		n = len( items )
		m = len( self.distributions )
		last_log_probability_sum = log_probability( self, items )

		iteration, improvement = 0, INF
		priors = numpy.log( self.weights )

		while improvement > stop_threshold and iteration < max_iterations:
			# The responsibility matrix
			r = self.a_posteriori( items )

			# Update the distribution based on the responsibility matrix
			for i, distribution in enumerate( self.distributions ):
				distribution.from_sample( items, weights=r[:,i], diagonal=diagonal )
				priors[i] = r[:,i].sum() / r.sum()

			trained_log_probability_sum = log_probability( self, items )
			improvement = trained_log_probability_sum - last_log_probability_sum
			last_log_probability_sum = trained_log_probability_sum

			if verbose:
				print( "Improvement: {}".format( improvement ) )

			iteration += 1

		self.weights = priors

	def a_posteriori( self, items ):
		"""
		Return the posterior probability of each distribution given the data.
		"""

		n, m = len( items ), len( self.distributions )
		priors = self.weights
		r = numpy.zeros( (n, m) ) 

		for i, item in enumerate( items ):
			# Counter for summation over the row
			r_sum = NEGINF

			# Calculate the log probability of the point over each distribution
			for j, distribution in enumerate( self.distributions ):
				# Calculate the log probability of the item under the distribution
				r[i, j] = distribution.log_probability( item )

				# Add the weights of the model
				r[i, j] += priors[j]

				# Add to the summation
				r_sum = pair_lse( r_sum, r[i, j] )

			# Normalize the row
			for j in xrange( m ):
				r[i, j] = cexp( r[i, j] - r_sum )

		return r

	def maximum_a_posteriori( self, items ):
		"""
		Return the most likely distribution given the posterior
		matrix. 
		"""

		posterior = self.a_posteriori( items )
		return numpy.argmax( axis=1 )