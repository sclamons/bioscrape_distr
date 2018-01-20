# cython: boundscheck=False
# cython: cdivision=True
# cython: wraparound=False

import numpy as np
from bs4 import BeautifulSoup
cimport numpy as np
cimport random as cyrandom
from vector cimport vector
import re
import sympy
from sympy.abc import _clash1
import warnings

from libc.math cimport log, sqrt, cos, round, exp, fabs

##################################################                ####################################################
######################################              PROPENSITY TYPES                    ##############################
#################################################                     ################################################


cdef class Propensity:
    def __init__(self):
        """
        Set the propensity type enum variable.
        """
        self.propensity_type = PropensityType.unset
    def py_get_propensity(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params,
                          double time = 0.0):
        """
        Calculate propensity in pure python given a state and parameter vector.
        :param state: (np.ndarray) state vector of doubles
        :param params: (np.ndarray) parameter vector of doubles.
        :return: (double) computed propensity, should be non-negative
        """
        return self.get_propensity(<double*> state.data, <double*> params.data, time)

    # must be overriden by the daughter class
    cdef double get_propensity(self, double* state, double* params, double time):
        """
        Compute the propensity given state and parameters (MUST be overridden, this returns -1.0)
        :param state: (double *) pointer to state vector
        :param params: (double *) pointer to parameter vector
        :param time: (double) the current time
        :return: (double) computed propensity, should be non-negative
        """
        return -1.0

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        """
        Compute the propensity given state and parameters and volume. (MUST be overridden)
        :param state: (double *) pointer to state vector
        :param params:(double *) pointer to parameter vector
        :param volume: (double) the cell volume
        :param time: (double) the current time
        :return: (double) computed propensity, should be non-negative
        """
        return -1.0

    def py_get_volume_propensity(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params,
                                 double volume, double time = 0.0):
        return self.get_volume_propensity(<double*> state.data, <double*> params.data, volume, time)



    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        """
        Initializes the parameters and species to look at the right indices in the state
        :param dictionary: (dict:str--> str) the fields for the propensity 'k','s1' etc map to the actual parameter
                                             and species names
        :param species_indices: (dict:str-->int) map species names to entry in species vector
        :param parameter_indices: (dict:str-->int) map param names to entry in param vector
        :return: nothing
        """
        pass

    def get_species_and_parameters(self, dict fields):
        """
        get which fields are species and which are parameters
        :param dict(str-->str) dictionary containing the XML attributes for that propensity to process.
        :return: (list(string), list(string)) First entry is the names of species, second entry is the names of parameters
        """
        return (None,None)



cdef class ConstitutivePropensity(Propensity):
    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.constitutive

    cdef double get_propensity(self, double* state, double* params, double time):
        return params[self.rate_index]

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        return params[self.rate_index] * volume

    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 'k':
                self.rate_index = parameter_indices[value]
            elif key == 'species':
                pass
            else:
                warnings.warn('Warning! Useless field for constitutive reaction', key)
    def get_species_and_parameters(self, dict fields):
        return ([],[fields['k']])




cdef class UnimolecularPropensity(Propensity):
    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.unimolecular

    cdef double get_propensity(self, double* state, double* params, double time):
        return params[self.rate_index] * state[self.species_index]

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        return params[self.rate_index] * state[self.species_index]


    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 'species':
                self.species_index = species_indices[value]
            elif key == 'k':
                self.rate_index = parameter_indices[value]
            else:
                warnings.warn('Useless field for unimolecular reaction', key)

    def get_species_and_parameters(self, dict fields):
        return ([ fields['species'] ],[ fields['k'] ])



cdef class BimolecularPropensity(Propensity):

    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.bimolecular

    cdef double get_propensity(self, double* state, double* params, double time):
        return params[self.rate_index] * state[self.s1_index] * state[self.s2_index]

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        return params[self.rate_index] * state[self.s1_index] * state[self.s2_index] / volume


    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 'species':
                species_names = [x.strip() for x in value.split('*')]
                species_names = [x for x in species_names if x != '']
                assert(len(species_names) == 2)
                self.s1_index = species_indices[species_names[0]]
                self.s2_index = species_indices[species_names[1]]
            elif key == 'k':
                self.rate_index = parameter_indices[value]
            else:
                warnings.warn('Useless field for bimolecular reaction', key)

    def get_species_and_parameters(self, dict fields):
        return ([ x.strip() for x in fields['species'].split('*') ],[ fields['k'] ])


cdef class PositiveHillPropensity(Propensity):

    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.hill_positive

    cdef double get_propensity(self, double* state, double* params, double time):
        cdef double X = state[self.s1_index]
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double rate = params[self.rate_index]
        return rate * (X / K) ** n / (1 + (X/K)**n)

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        cdef double X = state[self.s1_index] / volume
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double rate = params[self.rate_index]
        return rate * (X / K) ** n / (1 + (X/K)**n)

    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 's1':
                self.s1_index = species_indices[value]
            elif key == 'K':
                self.K_index = parameter_indices[value]
            elif key == 'n':
                self.n_index = parameter_indices[value]
            elif key == 'k':
                self.rate_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for Hill propensity', key)

    def get_species_and_parameters(self, dict fields):
        return ([ fields['s1'] ],[ fields['K'],fields['n'],fields['k'] ])


cdef class PositiveProportionalHillPropensity(Propensity):

    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.proportional_hill_positive

    cdef double get_propensity(self, double* state, double* params, double time):
        cdef double X = state[self.s1_index]
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double rate = params[self.rate_index]
        cdef double d = state[self.d_index]
        return rate * d *  (X / K) ** n / (1 + (X/K)**n)

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        cdef double X = state[self.s1_index] / volume
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double d = state[self.d_index]
        cdef double rate = params[self.rate_index]
        return d * rate * (X / K) ** n / (1 + (X/K)**n)


    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 's1':
                self.s1_index = species_indices[value]
            elif key == 'd':
                self.d_index = species_indices[value]
            elif key == 'K':
                self.K_index = parameter_indices[value]
            elif key == 'n':
                self.n_index = parameter_indices[value]
            elif key == 'k':
                self.rate_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for proportional Hill propensity', key)


    def get_species_and_parameters(self, dict fields):
        return ([ fields['s1'], fields['d'] ],[ fields['K'],fields['n'],fields['k'] ])



cdef class NegativeHillPropensity(Propensity):

    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.hill_negative

    cdef double get_propensity(self, double* state, double* params, double time):
        cdef double X = state[self.s1_index]
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double rate = params[self.rate_index]
        return rate * 1 / (1 + (X/K)**n)

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        cdef double X = state[self.s1_index] / volume
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double rate = params[self.rate_index]
        return rate * 1 / (1 + (X/K)**n)

    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 's1':
                self.s1_index = species_indices[value]
            elif key == 'K':
                self.K_index = parameter_indices[value]
            elif key == 'n':
                self.n_index = parameter_indices[value]
            elif key == 'k':
                self.rate_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for Hill propensity', key)

    def get_species_and_parameters(self, dict fields):
        return ([ fields['s1'] ],[ fields['K'],fields['n'],fields['k'] ])



cdef class NegativeProportionalHillPropensity(Propensity):

    # constructor
    def __init__(self):
        self.propensity_type = PropensityType.proportional_hill_negative

    cdef double get_propensity(self, double* state, double* params, double time):
        cdef double X = state[self.s1_index]
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double rate = params[self.rate_index]
        cdef double d = state[self.d_index]
        return rate * d *  1/ (1 + (X/K)**n)

    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        cdef double X = state[self.s1_index] / volume
        cdef double K = params[self.K_index]
        cdef double n = params[self.n_index]
        cdef double d = state[self.d_index]
        cdef double rate = params[self.rate_index]
        return d * rate * 1 / (1 + (X/K)**n)


    def initialize(self, dict dictionary, species_indices, parameter_indices):
        for key,value in dictionary.items():
            if key == 's1':
                self.s1_index = species_indices[value]
            elif key == 'd':
                self.d_index = species_indices[value]
            elif key == 'K':
                self.K_index = parameter_indices[value]
            elif key == 'n':
                self.n_index = parameter_indices[value]
            elif key == 'k':
                self.rate_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for proportional Hill propensity', key)

    def get_species_and_parameters(self, dict fields):
        return ([ fields['s1'], fields['d'] ],[ fields['K'],fields['n'],fields['k'] ])

    def set_species(self, species, species_indices):
        for key in species:
            if key == 's1':
                self.s1_index = species_indices[species['s1']]
            elif key == 'd':
                self.d_index = species_indices[species['d']]
            else:
                warnings.warn('Warning! Useless species for Hill propensity', key)
    def set_parameters(self,parameters, parameter_indices):
        for key in parameters:
            if key == 'K':
                self.K_index = parameter_indices[parameters[key]]
            elif key == 'n':
                self.n_index = parameter_indices[parameters[key]]
            elif key == 'k':
                self.rate_index = parameter_indices[parameters[key]]
            else:
                warnings.warn('Warning! Useless parameter for Hill propensity', key)



cdef class MassActionPropensity(Propensity):
    def __init__(self):
        self.propensity_type = PropensityType.mass_action

    cdef double get_propensity(self, double* state, double* params, double time):
        cdef double ans = params[self.k_index]
        cdef int i
        for i in range(self.num_species):
            ans *= state[self.sp_inds[i]]

        return ans

    cdef double get_volume_propensity(self, double *state, double *params,
                                      double volume, double time):
        cdef double ans = params[self.k_index]
        cdef int i
        for i in range(self.num_species):
            ans *= state[self.sp_inds[i]]
        if self.num_species == 1:
            return ans
        elif self.num_species == 2:
            return ans / volume
        elif self.num_species == 0:
            return ans * volume
        else:
            return ans / (volume ** (self.num_species - 1) )


    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        for key, value in dictionary.items():
            if key == 'species':
                if '+' in value or '-' in value:
                    raise SyntaxError('Plus or minus character in mass action propensity string.')
                species_names = [s.strip() for s in value.split('*')]
                for species_name in species_names:
                    if species_name == '':
                        continue
                    self.sp_inds.push_back(species_indices[species_name])
                self.num_species = self.sp_inds.size()
            elif key == 'k':
                self.k_index = parameter_indices[value]
            else:
                warnings.warn('Warning: useless field for mass action propensity', key)

    def get_species_and_parameters(self, dict fields):
        species_list = [x.strip()   for x in fields['species'].split('*') ]
        species_list = [x for x in species_list if x != '']

        return (species_list, [ fields['k'] ])


##################################################                ####################################################
######################################              PARSING                             ##############################
#################################################                     ################################################


cdef class Term:
    cdef double evaluate(self, double *species, double *params, double time):
        raise SyntaxError('Cannot make Term base object')

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        raise SyntaxError('Cannot make Term base object')


    def py_evaluate(self, np.ndarray species, np.ndarray params, double time=0.0):
        return self.evaluate(<double*> species.data, <double*> params.data, time)

    def py_volume_evaluate(self, np.ndarray species, np.ndarray params,
                           double vol, double time=0.0):
        return self.volume_evaluate(<double*> species.data, <double*> params.data,
                                    vol, time)

# Base building blocks

cdef class ConstantTerm(Term):

    def __init__(self, double val):
        self.value = val

    cdef double evaluate(self, double *species, double *params, double time):
        return self.value
    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return self.value

cdef class SpeciesTerm(Term):


    def __init__(self, unsigned ind):
        self.index = ind

    cdef double evaluate(self, double *species, double *params, double time):
        return species[self.index]
    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return species[self.index]

cdef class ParameterTerm(Term):

    def __init__(self, unsigned ind):
        self.index = ind

    cdef double evaluate(self, double *species, double *params, double time):
        return params[self.index]
    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return params[self.index]

cdef class VolumeTerm(Term):
    cdef double evaluate(self, double *species, double *params, double time):
        return 1.0
    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return vol

# Putting stuff together

cdef class SumTerm(Term):


    def __init__(self):
        self.terms_list = []

    cdef void add_term(self,Term trm):
        self.terms.push_back(<void*> trm)
        self.terms_list.append(trm)

    cdef double evaluate(self, double *species, double *params, double time):
        cdef double ans = 0.0
        cdef unsigned i
        for i in range(self.terms.size()):
            ans += (<Term>(self.terms[i])).evaluate(species, params, time)
        return ans

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        cdef double ans = 0.0
        cdef unsigned i
        for i in range(self.terms.size()):
            ans += (<Term>(self.terms[i])).volume_evaluate(species,params,vol, time)
        return ans

cdef class ProductTerm(Term):
    def __init__(self):
        self.terms_list = []

    cdef void add_term(self,Term trm):
        self.terms.push_back(<void*> trm)
        self.terms_list.append(trm)

    cdef double evaluate(self, double *species, double *params, double time):
        cdef double ans = 1.0
        cdef unsigned i
        for i in range(self.terms.size()):
            ans *= (<Term>(self.terms[i])).evaluate(species, params,time)
        return ans

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        cdef double ans = 1.0
        cdef unsigned i
        for i in range(self.terms.size()):
            ans *= (<Term>(self.terms[i])).volume_evaluate(species,params,vol,time)
        return ans

cdef class MaxTerm(Term):
    def __init__(self):
        self.terms_list = []

    cdef void add_term(self,Term trm):
        self.terms.push_back(<void*> trm)
        self.terms_list.append(trm)

    cdef double evaluate(self, double *species, double *params, double time):
        cdef double ans = (<Term>(self.terms[0])).evaluate(species, params,time)
        cdef unsigned i
        cdef double temp = 0
        for i in range(1,self.terms.size()):
            temp =  (<Term>(self.terms[i])).evaluate(species, params,time)
            if temp > ans:
                ans = temp

        return ans

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        cdef double ans = (<Term>(self.terms[0])).volume_evaluate(species,params,vol,time)
        cdef unsigned i
        cdef double temp = 0
        for i in range(1,self.terms.size()):
            temp = (<Term>(self.terms[i])).volume_evaluate(species,params,vol,time)
            if temp > ans:
                ans = temp
        return ans

cdef class MinTerm(Term):
    def __init__(self):
        self.terms_list = []

    cdef void add_term(self,Term trm):
        self.terms.push_back(<void*> trm)
        self.terms_list.append(trm)

    cdef double evaluate(self, double *species, double *params, double time):
        cdef double ans = (<Term>(self.terms[0])).evaluate(species, params,time)
        cdef unsigned i
        cdef double temp = 0
        for i in range(1,self.terms.size()):
            temp =  (<Term>(self.terms[i])).evaluate(species, params,time)
            if temp < ans:
                ans = temp

        return ans

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        cdef double ans = (<Term>(self.terms[0])).volume_evaluate(species,params,vol,time)
        cdef unsigned i
        cdef double temp = 0
        for i in range(1,self.terms.size()):
            temp = (<Term>(self.terms[i])).volume_evaluate(species,params,vol,time)
            if temp < ans:
                ans = temp
        return ans

cdef class PowerTerm(Term):


    cdef void set_base(self, Term base):
        self.base = base
    cdef void set_exponent(self, Term exponent):
        self.exponent = exponent

    cdef double evaluate(self, double *species, double *params, double time):
        return self.base.evaluate(species,params,time) ** \
               self.exponent.evaluate(species,params,time)

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return self.base.volume_evaluate(species,params,vol,time) ** \
               self.exponent.volume_evaluate(species,params,vol,time)


cdef class ExpTerm(Term):
    cdef void set_arg(self, Term arg):
        self.arg = arg

    cdef double evaluate(self, double *species, double *params, double time):
        return exp(self.arg.evaluate(species,params,time))

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return exp(self.arg.volume_evaluate(species,params,vol,time))

cdef class LogTerm(Term):
    cdef void set_arg(self, Term arg):
        self.arg = arg

    cdef double evaluate(self, double *species, double *params, double time):
        return log(self.arg.evaluate(species,params,time))

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return log(self.arg.volume_evaluate(species,params,vol,time))


cdef class StepTerm(Term):
    cdef void set_arg(self, Term arg):
        self.arg = arg

    cdef double evaluate(self, double *species, double *params, double time):
        if self.arg.evaluate(species,params,time) >= 0:
            return 1.0
        return 0

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        if self.arg.volume_evaluate(species,params,vol,time) >= 0:
            return 1.0
        return 0

cdef class AbsTerm(Term):
    cdef void set_arg(self, Term arg):
        self.arg = arg

    cdef double evaluate(self, double *species, double *params, double time):
        return fabs( self.arg.evaluate(species,params,time) )

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return fabs( self.arg.volume_evaluate(species,params,vol,time) )


cdef class TimeTerm(Term):
    cdef double evaluate(self, double *species, double *params, double time):
        return time

    cdef double volume_evaluate(self, double *species, double *params, double vol, double time):
        return time


def sympy_species_and_parameters(instring):
    instring = instring.replace('^','**')
    instring = instring.replace('|','_')
    root = sympy.sympify(instring, _clash1)
    nodes = [root]
    index = 0
    while index < len(nodes):
        node = nodes[index]
        index += 1
        nodes.extend(node.args)

    names = [str(n) for n in nodes if type(n) == sympy.Symbol]

    species_names = [s for s in names if (s[0] != '_' and s != 'volume' and s != 't')]
    param_names = [s[1:] for s in names if s[0] == '_']

    return species_names,param_names

def sympy_recursion(tree, species2index, params2index):
    cdef SumTerm sumterm
    cdef ProductTerm productterm
    cdef PowerTerm powerterm
    cdef ExpTerm expterm
    cdef LogTerm logterm
    cdef StepTerm stepterm
    cdef AbsTerm absterm
    cdef MaxTerm maxterm
    cdef MinTerm minterm

    root = tree.func
    args = tree.args
    # check if symbol
    if type(tree) == sympy.Symbol:
        name = str(tree)
        if name[0] == '_':
            return ParameterTerm(params2index[ name[1:] ])
        elif name == 'volume':
            return VolumeTerm()
        elif name == 't':
            return TimeTerm()
        else:
            return SpeciesTerm(species2index[ name ])
    # check if addition
    elif type(tree) == sympy.Add:
        sumterm = SumTerm()
        for a in args:
            sumterm.add_term(  sympy_recursion(a,species2index,params2index)   )
        return sumterm

    # check multiplication
    elif type(tree) == sympy.Mul:
        productterm = ProductTerm()
        for a in args:
            productterm.add_term(sympy_recursion(a,species2index,params2index))
        return productterm

    # check exponential

    elif type(tree) == sympy.Pow:
        powerterm = PowerTerm()
        powerterm.set_base( sympy_recursion(args[0],species2index,params2index) )
        powerterm.set_exponent( sympy_recursion(args[1], species2index,params2index) )
        return powerterm


    # check exp and log

    elif type(tree) == sympy.exp:
        expterm = ExpTerm()
        expterm.set_arg( sympy_recursion(args[0],species2index,params2index) )
        return expterm

    elif type(tree) == sympy.log:
        logterm = LogTerm()
        logterm.set_arg( sympy_recursion(args[0],species2index,params2index) )
        return logterm

    # check Heaviside

    elif type(tree) == sympy.Heaviside:
        stepterm = StepTerm()
        stepterm.set_arg( sympy_recursion(args[0],species2index,params2index) )
        return stepterm

    # check absolute value

    elif type(tree) == sympy.Abs:
        absterm = AbsTerm()
        absterm.set_arg( sympy_recursion(args[0],species2index,params2index) )
        return absterm

    # check for min and max

    elif type(tree) == sympy.Max:
        maxterm = MaxTerm()
        for a in args:
            maxterm.add_term(sympy_recursion(a,species2index,params2index))
        return maxterm

    elif type(tree) == sympy.Min:
        minterm = MinTerm()
        for a in args:
            minterm.add_term(sympy_recursion(a,species2index,params2index))
        return minterm

    # if nothing else, then it should be a number

    else:
        try:
            return ConstantTerm(float( tree.evalf() ))
        except:
            raise SyntaxError('This should be a number: ' + str(tree))



def parse_expression(instring, species2index, params2index):
    instring = instring.strip()
    instring = instring.replace('^','**')
    instring = instring.replace('|', '_')
    instring = instring.replace('heaviside', 'Heaviside')

    try:
        parse_tree = sympy.sympify(instring, _clash1)
    except:
        raise SyntaxError('Sympy unable to parse: ' + instring)

    return sympy_recursion(parse_tree,species2index,params2index)


cdef class GeneralPropensity(Propensity):

    cdef double get_propensity(self, double* state, double* params, double time):
        return self.term.evaluate(state,params,time)
    cdef double get_volume_propensity(self, double *state, double *params, double volume, double time):
        return self.term.volume_evaluate(state,params,volume,time)

    def __init__(self):
        self.propensity_type = PropensityType.general

    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        instring = dictionary['rate']

        self.term = parse_expression(instring, species_indices, parameter_indices)


    def get_species_and_parameters(self, dict fields):
        instring = fields['rate'].strip()
        return sympy_species_and_parameters(instring)



##################################################                ####################################################
######################################              DELAY TYPES                        ##############################
#################################################                     ################################################

cdef class Delay:
    def __init__(self):
        """
        Set the delay_type attribute to the appropriate enum value.
        """

        self.delay_type = DelayType.unset_delay

    def py_get_delay(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params):
        """
        Return the delay given the state and parameter vector
        :param state: (np.ndarray) the state vector
        :param params: (np.ndarray) the parameters vector
        :return: (double) the computed delay

        This function should NOT be overridden by subclases. It is just a Python wrapped of the cython delay function.
        """
        return self.get_delay(<double*> state.data, <double*> params.data)



    cdef double get_delay(self, double* state, double* params):
        """
        Compute a delay given the state and parameters vectors.
        :param state: (double *) the array containing the state vector
        :param params: (double *) the array containing the parameters vector
        :return: (double) the computed delay.

        This function must be overridden by subclasses.
        """

        return -1.0

    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        """
        Initializes the parameters and species to look at the right indices in the state
        :param dictionary: (dict:str--> str) the fields for the propensity 'k','s1' etc map to the actual parameter
                                             and species names
        :param species_indices: (dict:str-->int) map species names to entry in species vector
        :param parameter_indices: (dict:str-->int) map param names to entry in param vector
        :return: nothing
        """
        pass

    def get_species_and_parameters(self, dict fields):
        """
        get which fields are species and which are parameters
        :return: (list(string), list(string)) First entry is the fields that are species, second entry is the fields
                                              that are parameters
        """
        return [],[]


cdef class NoDelay(Delay):
    def __init__(self):
        self.delay_type = DelayType.none

    cdef double get_delay(self, double* state, double* params):
        return 0.0

cdef class FixedDelay(Delay):

    def __init__(self):
        self.delay_type = DelayType.fixed

    cdef double get_delay(self, double* state, double* params):
        return params[self.delay_index]

    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        for key,value in dictionary.items():
            if key == 'delay':
                self.delay_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for fixed delay', key)

    def get_species_and_parameters(self, dict fields):
        return [], [fields['delay']]

cdef class GaussianDelay(Delay):

    def __init__(self):
        self.delay_type = DelayType.gaussian

    cdef double get_delay(self, double* state, double* params):
        return cyrandom.normal_rv(params[self.mean_index],params[self.std_index])


    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        for key,value in dictionary.items():
            if key == 'mean':
                self.mean_index = parameter_indices[value]
            elif key == 'std':
                self.std_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for gaussian delay', key)

    def get_species_and_parameters(self, dict fields):
        return [],[fields['mean'], fields['std']]



cdef class GammaDelay(Delay):

    def __init__(self):
        self.delay_type = DelayType.gamma

    cdef double get_delay(self, double* state, double* params):
        return cyrandom.gamma_rv(params[self.k_index],params[self.theta_index])

    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        for key,value in dictionary.items():
            if key == 'k':
                self.k_index = parameter_indices[value]
            elif key == 'theta':
                self.theta_index = parameter_indices[value]
            else:
                warnings.warn('Warning! Useless field for gamma delay', key)

    def get_species_and_parameters(self, dict fields):
        return [],[fields['k'], fields['theta']]

##################################################                ####################################################
######################################              RULE   TYPES                       ###############################
#################################################                     ################################################

cdef class Rule:
    """
    A class for doing rules that must be done either at the beginning of a simulation or repeatedly at each step of
    the simulation.
    """
    cdef void execute_rule(self, double *state, double *params, double time):
        raise NotImplementedError('Creating base Rule class. This should be subclassed.')

    cdef void execute_volume_rule(self, double *state, double *params, double volume, double time):
        self.execute_rule(state, params, time)

    def py_execute_rule(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params,
                        double time = 0.0):
        self.execute_rule(<double*> state.data, <double*> params.data,time)

    def py_execute_volume_rule(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params,
                               double volume, double time=0.0 ):
        self.execute_volume_rule(<double*> state.data, <double*> params.data, volume,time)

    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        """
        Initializes the parameters and species to look at the right indices in the state
        :param dictionary: (dict:str--> str) the fields for the propensity 'k','s1' etc map to the actual parameter
                                             and species names
        :param species_indices: (dict:str-->int) map species names to entry in species vector
        :param parameter_indices: (dict:str-->int) map param names to entry in param vector
        :return: nothing
        """
        pass

    def get_species_and_parameters(self, dict fields):
        """
        get which fields are species and which are parameters
        :param dict(str-->str) dictionary containing the XML attributes for that propensity to process.
        :return: (list(string), list(string)) First entry is the names of species, second entry is the names of parameters
        """
        return (None,None)


cdef class AdditiveAssignmentRule(Rule):
    """
    A class for assigning a species to a sum of a bunch of other species.
    """

    cdef void execute_rule(self, double *state, double *params, double time):
        cdef unsigned i = 0
        cdef double answer = 0.0
        for i in range(self.species_source_indices.size()):
            answer += state[ self.species_source_indices[i] ]

        state[self.dest_index] = answer

    def initialize(self, dict dictionary, dict species_indices, dict parameter_indices):
        equation = dictionary['equation']
        split_eqn = [s.strip() for s in equation.split('=') ]
        assert(len(split_eqn) == 2)
        dest_name = split_eqn[0]
        src_names = [s.strip() for s in split_eqn[1].split('+')]

        self.dest_index = species_indices[dest_name]

        for string in src_names:
            self.species_source_indices.push_back(  species_indices[string]  )

    def get_species_and_parameters(self, dict fields):
        # Add the species names
        equation = fields['equation']
        split_eqn = [s.strip() for s in equation.split('=') ]
        assert(len(split_eqn) == 2)
        dest_name = split_eqn[0]
        species_names = [s.strip() for s in split_eqn[1].split('+')]
        species_names.append(dest_name)
        return species_names, []

cdef class GeneralAssignmentRule(Rule):
    """
    A class for doing rules that must be done either at the beginning of a simulation or repeatedly at each step of
    the simulation.
    """
    cdef void execute_rule(self, double *state, double *params, double time):
        if self.param_flag > 0:
            params[self.dest_index] = self.rhs.evaluate(state,params,time)
        else:
            state[self.dest_index] = self.rhs.evaluate(state,params,time)

    cdef void execute_volume_rule(self, double *state, double *params, double volume, double time):
        if self.param_flag > 0:
            params[self.dest_index] = self.rhs.volume_evaluate(state,params,volume, time)
        else:
            state[self.dest_index] = self.rhs.volume_evaluate(state,params,volume, time)

    def initialize(self, dict fields, species2index, params2index):
        self.rhs = parse_expression(fields['equation'].split('=')[1], species2index, params2index)

        dest_name = fields['equation'].split('=')[0].strip()

        if dest_name[0] == '_' or dest_name[0] == '|':
            self.param_flag = 1
            self.dest_index = params2index[dest_name[1:]]
        else:
            self.param_flag = 0
            self.dest_index = species2index[dest_name]

    def get_species_and_parameters(self, dict fields):
        instring = fields['equation'].strip()
        dest_name = instring.split('=')[0].strip()
        instring = instring.split('=')[1]

        species_names, param_names = sympy_species_and_parameters(instring)

        if dest_name[0] == '_' or dest_name[0] == '|':
            param_names.append(dest_name[1:])
        else:
            species_names.append(dest_name)

        return species_names, param_names


##################################################                ####################################################
######################################              VOLUME TYPES                        ##############################
#################################################                     ################################################

cdef class Volume:
    cdef double get_volume_step(self, double *state, double *params, double time, double volume, double dt):
        """
        Return the volume change in a time step of dt ending at time t given the state, parameters, and volume at t-d

        Must be overridden by subclass

        :param state: (double *) pointer to state vector
        :param params: (double *) pointer to parameter vector
        :param time: (double) ending time after the volume step has occurred
        :param volume: (double) the volume before the volume step occurs
        :param dt: (double) the time step over which you want the volume change
        :return: (double) the change in cell volume from time - dt to time
        """

        return 0.0

    cdef Volume copy(self):
        """
        Returns a deep copy of the volume object
        """
        raise NotImplementedError('Need to implement copy for population simulations')

    def py_copy(self):
        """
        Copy function for deep copying
        :return: a deep copy of the volume object
        """
        return self.copy()

    def py_get_volume_step(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params,
                           double time, double volume, double dt):
        return self.get_volume_step(<double*> state.data, <double*> params.data, time, volume, dt)


    cdef void initialize(self, double *state, double *params, double time, double volume):
        """
        Initialize the volume object given a new initial time and volume and the current state and parameters.

        This is required in order to handle non-memoryless properties, like the cell division time, which can be
        pre-sampled once in the initialize() function and then simply queried later.

        Must be overridden by subclass.

        :param state: (double *) pointer to the state vector
        :param params: (double *) pointer to the parameter vector
        :param time: (double) current initial time
        :param volume: (double) initial volume
        :return: None
        """

        pass

    def py_initialize(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params,
                      double time, double volume):
        self.initialize(<double*> state.data, <double*> params.data, time, volume)

    cdef unsigned cell_divided(self, double *state, double *params, double time, double volume, double dt):
        """
        Return true or false if the cell divided during the time interval between time-dt and time. Note, in order
        to compute this the cell should have already been updated up to time t first.

        Must be overridden by subclass.

        :param state: (double *) pointer to the state vector
        :param params: (double *) pointer to parameter vector
        :param time: (double) the ending time of the time step
        :param volume: (double) the volume AFTER the time step occurred
        :param dt: (double) the width of the time step
        :return: 1 if the cell divided in [time-dt, time] or 0 if it did not divide.
        """

        return 0

    def py_cell_divided(self, np.ndarray[np.double_t,ndim=1] state, np.ndarray[np.double_t,ndim=1] params, double time,
                        double volume, double dt):
        return self.cell_divided(<double*> state.data, <double*> params.data, time, volume, dt)


    def py_set_volume(self, double v):
        self.set_volume(v)
    def py_get_volume(self):
        return self.get_volume()




cdef class StochasticTimeThresholdVolume(Volume):
    def __init__(self, double cell_cycle_time, double average_division_volume, double division_noise):
        """
        Initialize the class with the cell cycle time, average division volume, and noise parameter.

        :param cell_cycle_time: (double) cell cycle time on average
        :param average_division_volume: (double) average volume at division
        :param division_noise: (double) noise in the cell cycle time as a relative c.o.v.
        """
        self.cell_cycle_time = cell_cycle_time
        self.average_division_volume = average_division_volume
        self.division_noise = division_noise
        self.division_time = -1.0

        # Compute growth rate yourself.
        self.growth_rate = 0.69314718056 / cell_cycle_time # log(2) / cycle time


    cdef Volume copy(self):
        cdef StochasticTimeThresholdVolume v = StochasticTimeThresholdVolume(self.cell_cycle_time,
                                                                             self.average_division_volume,
                                                                             self.division_noise)
        v.division_time = self.division_time
        v.current_volume = self.current_volume
        return v

    cdef double get_volume_step(self, double *state, double *params, double time, double volume, double dt):
        """
        Compute a deterministic volume step that is independent of state and parameters.

        :param state: (double *) the state vector. not used here
        :param params: (double *) the parameter vector. not used here
        :param time: (double) the final time.
        :param volume: (double) the volume at time - dt
        :param dt: (double) the time step
        :return:
        """

        return ( exp(self.growth_rate*dt) - 1.0) * volume

    cdef void initialize(self, double *state, double *params, double time, double volume):
        """
        Initialize the volume by setting initial time and volume and sampling the division time ahead of time with
        the the time left to division being the deterministic time left given the growth rate, cell cycle time,
        average division volume, and current volume. Then the actual time left to division is normal(1.0, noise) * T,
         where noise is the division noise parameter. This sets the future division time.

        :param state: (double *) the state vector. not used here
        :param params: (double *) the parameter vector. not used here
        :param time: (double) current time
        :param volume: (double) current volume
        :return:
        """

        self.set_volume(volume)
        cdef double time_left = log(self.average_division_volume / volume) / self.growth_rate
        time_left = cyrandom.normal_rv(1.0, self.division_noise) * time_left
        self.division_time = time + time_left
        #print("Volume:", volume, "Division Time:", self.division_time )

    cdef unsigned  cell_divided(self, double *state, double *params, double time, double volume, double dt):
        """
        Check if the cell has divided in the interval time-dt to time. Does not depend on any of the parameters for
         this volume type.

        :param state: (double *) the state vector. not used here
        :param params: (double *) the parameter vector. not used here
        :param time: (double) current time
        :param volume: (double) current volume
        :param dt: (double) time step
        :return: 1 if cell divided, 0 otherwise
        """


        if self.division_time > time - dt and self.division_time <= time:
            return 1
        return 0

cdef class StateDependentVolume(Volume):
    """
    A volume class for a cell where growth rate depends on state and the division volume is chosen randomly
    ahead of time with some randomness.

    Attributes:
        division_volume (double): the volume at which the cell will divide.
        average_division_volume (double): the average volume at which to divide.
        division_noise (double):  << 1, the noise in the division time (c.o.v.)
        growth_rate (Term): the growth rate evaluated based on the state
    """

    def __init__(self):
        pass

    def setup(self, double average_division_volume, double division_noise, growth_rate, Model m):
        self.average_division_volume = average_division_volume
        self.division_noise = division_noise
        self.growth_rate = m.parse_general_expression(growth_rate)


    cdef double get_volume_step(self, double *state, double *params, double time, double volume, double dt):
        cdef double gr = self.growth_rate.evaluate(state,params, time)
        return ( exp(gr*dt) - 1.0) * volume

    cdef void initialize(self, double *state, double *params, double time, double volume):
        self.py_set_volume(volume)
        # Must choose division volume.
        self.division_volume = self.average_division_volume * cyrandom.normal_rv(1.0, self.division_noise)
        if self.division_noise > volume:
            raise RuntimeError('Division occurs before initial volume - change your parameters!')


    cdef unsigned cell_divided(self, double *state, double *params, double time, double volume, double dt):
        if volume > self.division_volume:
            return 1
        return 0

    cdef Volume copy(self):
        cdef StateDependentVolume sv = StateDependentVolume()
        sv.division_noise = self.division_noise
        sv.division_volume = self.division_volume
        sv.growth_rate = self.growth_rate
        sv.average_division_volume = self.average_division_volume
        sv.current_volume = self.current_volume
        return sv


##################################################                ####################################################
######################################              MODEL   TYPES                       ##############################
#################################################                     ################################################

cdef class Model:
    def __init__(self, filename):
        """
        Read in a model from a file using XML format for the model.

        :param filename: (str) the file to read the model
        """

        self._next_species_index = 0
        self._next_params_index = 0
        self.parse_model(filename)

    def _add_species(self, species):
        """
        Helper function for putting together the species vector (converting species names to indices in vector)

        If the species has already been added, then do nothing. otherwise give it a new index, and increase
        the next_species_index by 1

        :param species: (str) the species name
        :return: None
        """

        if species not in self.species2index:
            self.species2index[species] = self._next_species_index
            self._next_species_index += 1


    def _add_param(self, param):
        """
        Helper function for putting together the parameter vector (converting parameter names to indices in vector)

        If the parameter name has already been seen, then do nothing. Otherwise, give it a new index, and increase the
        next_params_index by 1.

        :param param: (str) the parameter name
        :return: None
        """

        if param not in self.params2index:
            self.params2index[param] = self._next_params_index
            self._next_params_index += 1


    def parse_model(self, filename):
        """
        Parse the model from the file filling in all the local variables (propensities, delays, update arrays). Also
        maps the species and parameters to indices in a species and parameters vector.

        :param filename: (str or file) the model file. if a string, the file is opened. otherwise, it is assumed
                         that a file handle was passed in.
        :return: None
        """


        # open XML file from the filename and use BeautifulSoup to parse it
        if type(filename) == str:
            xml_file = open(filename,'r')
        else:
            xml_file = filename
        xml = BeautifulSoup(xml_file,features="xml")
        xml_file.close()
        # Go through the reactions and parse them 1 by 1 keeping track of species and reactions

        # Brief Outline
        #
        # Any time a species or parameter name is seen, add it to the index mapping names to indices if it has not
        # already been added.
        #
        # 1. For each reaction XML tag, parse the text to get the reactants and products. create a dictionary for each
        #    reaction that maps the species involved in each reaction to its update in the reaction i.e. for TX, you
        #    would have reaction_update_dict['mRNA'] = +1.0
        # 2. For each reaction, also do the same thing for the delayed updates.
        # 3. Parse the propensity and delay for each reaction and create the appropriate object for each and initialize
        #    by calling set_species and set_parameters for each.
        # 4. At the very end, with the params2index and species2index fully populated, use the saved updated dicts to re-
        #    construct the update array and delay update array.
        # 5. Read in the intial species and parameters values. If a species is not set, print a warning and set to 0.
        #    If a parameter is not set, throw an error.


        # check for model tag at beginning.

        Model = xml.find_all('model')
        if len(Model) != 1:
            raise SyntaxError('Did not include global model tag in XML file')


        self._next_species_index = 0
        self._next_params_index = 0
        self.species2index = {}
        self.params2index = {}
        self.propensities = []
        self.delays = []
        self.repeat_rules = []

        reaction_updates = []
        delay_reaction_updates = []
        reaction_index = 0

        Reactions = xml.find_all('reaction')
        for reaction in Reactions:
            # create a new set of updates
            reaction_update_dict = {}

            # Parse the stoichiometry
            text = reaction['text']
            reactants = [s for s in [r.strip() for r in text.split('--')[0].split('+')] if s]
            products = [s for s in [r.strip() for r in text.split('--')[1].split('+')] if s]

            for r in reactants:
                # if the species hasn't been seen add it to the index
                self._add_species(r)
                # update the update array
                if r not in reaction_update_dict:
                    reaction_update_dict[r] = 0
                reaction_update_dict[r]  -= 1

            for p in products:
                # if the species hasn't been seen add it to the index
                self._add_species(p)
                # update the update array
                if p not in reaction_update_dict:
                    reaction_update_dict[p] = 0
                reaction_update_dict[p]  += 1

            reaction_updates.append(reaction_update_dict)


            # parse the delayed part of the reaction the same way as we did before.
            delay_reaction_update_dict = {}

            if reaction.has_attr('after'):
                text = reaction['after']
                reactants = [s for s in [r.strip() for r in text.split('--')[0].split('+')] if s]
                products = [s for s in [r.strip() for r in text.split('--')[1].split('+')] if s]

                for r in reactants:
                    # if the species hasn't been seen add it to the index
                    self._add_species(r)
                    # update the update array
                    if r not in delay_reaction_update_dict:
                        delay_reaction_update_dict[r] = 0
                    delay_reaction_update_dict[r]  -= 1

                for p in products:
                    # if the species hasn't been seen add it to the index
                    self._add_species(p)
                    # update the update array
                    if p not in delay_reaction_update_dict:
                        delay_reaction_update_dict[p] = 0
                    delay_reaction_update_dict[p]  += 1

            delay_reaction_updates.append(delay_reaction_update_dict)


            # Then look at the propensity and set up a propensity object
            propensity = reaction.find_all('propensity')
            if len(propensity) != 1:
                raise SyntaxError('Incorrect propensity tags in XML model\n' + propensity)
            propensity = propensity[0]
            # go through propensity types

            init_dictionary = propensity.attrs

            if propensity['type'] == 'hillpositive':
                prop_object = PositiveHillPropensity()

            elif propensity['type'] == 'proportionalhillpositive':
                prop_object = PositiveProportionalHillPropensity()

            elif propensity['type'] == 'hillnegative':
                prop_object = NegativeHillPropensity()

            elif propensity['type'] == 'proportionalhillnegative':
                prop_object = NegativeProportionalHillPropensity()

            elif propensity['type'] == 'massaction':
                species_names = [s.strip() for s in propensity['species'].split('*') ]
                species_names = [x for x in species_names if x != '']

                # if mass action propensity has less than 3 things, then use consitutitve, uni, bimolecular for speed.
                if len(species_names) == 0:
                    prop_object = ConstitutivePropensity()
                elif len(species_names) == 1:
                    prop_object = UnimolecularPropensity()
                elif len(species_names) == 2:
                    prop_object = BimolecularPropensity()
                else:
                    prop_object = MassActionPropensity()

            elif propensity['type'] == 'general':
                prop_object = GeneralPropensity()

            else:
                raise SyntaxError('Propensity Type makes no sense: ' + propensity['type'])

            species_names, param_names = prop_object.get_species_and_parameters(init_dictionary)

            for species_name in species_names:
                self._add_species(species_name)
            for param_name in param_names:
                self._add_param(param_name)

            init_dictionary.pop('type')
            prop_object.initialize(init_dictionary,self.species2index,self.params2index)

            self.propensities.append(prop_object)
            self.c_propensities.push_back(<void*> prop_object)


            # Then look at the delay and set up a delay object
            delay = reaction.find_all('delay')
            if len(delay) != 1:
                raise SyntaxError('Incorrect delay spec')
            delay = delay[0]
            init_dictionary = delay.attrs

            if delay['type'] == 'none':
                delay_object = NoDelay()

            elif delay['type'] == 'fixed':
                delay_object = FixedDelay()

            elif delay['type'] == 'gaussian':
                delay_object = GaussianDelay()

            elif delay['type'] == 'gamma':
                delay_object = GammaDelay()

            else:
                raise SyntaxError('Unknown delay type: ' + delay['type'])

            species_names, param_names = delay_object.get_species_and_parameters(init_dictionary)

            for species_name in species_names:
                self._add_species(species_name)
            for param_name in param_names:
                self._add_param(param_name)

            init_dictionary.pop('type',None)
            delay_object.initialize(init_dictionary,self.species2index,self.params2index)

            self.delays.append(delay_object)
            self.c_delays.push_back(<void*> delay_object)


        # Parse through the rules

        Rules = xml.find_all('rule')
        cdef Rule rule_object
        for rule in Rules:
            init_dictionary = rule.attrs
            # Parse the rule by rule type
            if rule['type'] == 'additive':
                rule_object = AdditiveAssignmentRule()
            elif rule['type'] == 'assignment':
                rule_object = GeneralAssignmentRule()
            else:
                raise SyntaxError('Invalid type of Rule: ' + rule['type'])

            # Add species and params to model
            species_names, params_names = rule_object.get_species_and_parameters(init_dictionary)
            for s in species_names: self._add_species(s)
            for p in params_names: self._add_param(p)

            # initialize the rule
            init_dictionary.pop('type')
            rule_object.initialize(init_dictionary,self.species2index,self.params2index)
            # Add the rule to the right place
            if rule['frequency'] == 'repeated':
                self.repeat_rules.append(rule_object)
                self.c_repeat_rules.push_back(<void*> rule_object)
            else:
                raise SyntaxError('Invalid Rule Frequency: ' + rule['frequency'])

        # With all reactions read in, generate the update array

        num_species = len(self.species2index.keys())
        num_reactions = len(Reactions)
        self.update_array = np.zeros((num_species, num_reactions))
        self.delay_update_array = np.zeros((num_species,num_reactions))
        for reaction_index in range(num_reactions):
            reaction_update_dict = reaction_updates[reaction_index]
            delay_reaction_update_dict = delay_reaction_updates[reaction_index]
            for sp in reaction_update_dict:
                self.update_array[self.species2index[sp],reaction_index] = reaction_update_dict[sp]
            for sp in delay_reaction_update_dict:
                self.delay_update_array[self.species2index[sp],reaction_index] = delay_reaction_update_dict[sp]


        # Generate species values and parameter values
        self.params_values = np.empty(len(self.params2index.keys()), )
        self.params_values.fill(np.nan)
        unspecified_param_names = set(self.params2index.keys())
        Parameters = xml.find_all('parameter')
        for param in Parameters:
            param_value = float(param['value'])
            param_name = param['name']
            if param_name not in self.params2index:
                warnings.warn('Warning! Useless parameter '+ param_name)
            else:
                param_index = self.params2index[param_name]
                self.params_values[param_index] = param_value
                unspecified_param_names.remove(param_name)

        if len(unspecified_param_names) > 0:
                error_string = 'Did not specify parameters: '
                for pn in unspecified_param_names:
                    error_string += pn
                    error_string += ', '
                error_string = error_string[:len(error_string)-2]
                raise SyntaxError(error_string)

        self.species_values = np.empty(len(self.species2index.keys()), )
        self.species_values.fill(np.nan)
        unspecified_species_names = set(self.species2index.keys())
        Species = xml.find_all('species')
        for species in Species:
            species_value = float(species['value'])
            species_name = species['name']
            if species_name not in self.species2index:
                print ('Warning! Useless species value ' + species_name)
            else:
                species_index = self.species2index[species_name]
                self.species_values[species_index] = species_value
                unspecified_species_names.remove(species_name)

        if len(unspecified_species_names) > 0:
            error_string = "Didn't specify all species, setting the following to 0: "
            for sn in unspecified_species_names:
                error_string += (sn + ', ')
            error_string = error_string[:len(error_string)-2]
            warnings.warn(error_string)

        self.species_values[np.isnan(self.species_values)] = 0.0


        #print(self.species2index)
        #print(self.params2index)
        #print(self.update_array)
        #print(self.delay_update_array)

    def get_species_list(self):
        l = [None] * self.get_number_of_species()
        for s in self.species2index:
            l[self.species2index[s]] = s
        return l

    def get_param_list(self):
        l = [None] * self.get_number_of_params()
        for p in self.params2index:
            l[self.params2index[p]] = p
        return l

    def get_params(self):
        """
        Get the set of parameter names.
        :return: (dict_keys str) the parameter names
        """

        return self.params2index.keys()

    def get_number_of_params(self):
        return len(self.params2index.keys())


    def get_species(self):
        """
        Get the set of species names.
        :return: (dict_keys str) the species names
        """

        return self.species2index.keys()

    def get_number_of_species(self):
        return len(self.species2index.keys())


    def set_params(self, param_dict):
        """
        Set parameter values

        :param param_dict: (dict:str -> double) Dictionary containing the parameters to set mapped to desired values.
        :return: None
        """

        param_names = set(self.params2index.keys())
        for p in param_dict:
            if p in param_names:
                self.params_values[self.params2index[p]] = param_dict[p]
            else:
                warnings.warn('Trying to set parameter that is not in model: %s'  % p)


    def set_species(self, species_dict):
        """
        Set initial species values

        :param species_dict: (dict:str -> double) Dictionary containing the species to set mapped to desired values.
        :return: None
        """
        species_names = set(self.species2index.keys())
        for s in species_dict:
            if s in species_names:
                self.species_values[self.species2index[s]] = species_dict[s]
            else:
                warnings.warn('Trying to set species that is not in model: %s' % s)

    cdef (vector[void*])* get_c_repeat_rules(self):
        """
        Get the set of rules to implement as a set of void pointers. Must be cast back to a Rule object to be used.
        This is much faster than accessing the Rules as a list though.
        :return: (vector[void*])* pointer to the vector of Rule objects
        """
        return & self.c_repeat_rules

    def get_propensities(self):
        """
        Get the propensities list.

        :return: (list) List of the propensities for each reaction.
        """
        return self.propensities

    def get_delays(self):
        """
        Get the delays list

        :return: (list) List of the delay objects for each reaction.
        """
        return self.delays

    cdef np.ndarray get_species_values(self):
        """
        Get the species values as an array
        :return: (np.ndarray) the species values
        """

        return self.species_values

    cdef np.ndarray get_params_values(self):
        """
        Get the parameter values as an array
        :return: (np.ndarray) the parameter values
        """
        return self.params_values

    cdef (vector[void*])* get_c_propensities(self):
        """
        Get the propensity objects for each reaction as a vector of void pointers. Must be cast back to Propensity
        type to use. This is much faster than accessing the list of propensities.
        :return: (vector[void*]*) Pointer to a vector of void pointers, where i-th void pointer points to propensity i
        """
        return & self.c_propensities

    cdef (vector[void*])* get_c_delays(self):
        """
        Get the delay objects for each reaction as a vector of void pointers. Must be cast back to Delay.
        :return: (vector[void*] *) Pointer to vector of void *, where the i-th void pointer points to delay for rxn i
        """
        return & self.c_delays

    cdef np.ndarray get_update_array(self):
        """
        Get the stoichiometric matrix for changes that occur immdeiately.
        :return: (np.ndarray) A 2-D array with 1 row per species, 1 column for each reaction.
        """
        return self.update_array

    def py_get_update_array(self):
        return self.update_array

    cdef np.ndarray get_delay_update_array(self):
        """
        Get the stoichiometric matrix for changes that occur after a delay.
        :return: (np.ndarray) A 2-D array with 1 row per species, 1 column for each reaction.
        """
        return self.delay_update_array

    def py_get_delay_update_array(self):
        return self.delay_update_array


    def get_param_index(self, param_name):
        if param_name in self.params2index:
            return self.params2index[param_name]
        return -1


    def get_species_index(self, species_name):
        if species_name in self.species2index:
            return self.species2index[species_name]
        return -1

    def get_param_value(self, param_name):
        if param_name in self.params2index:
            return self.params_values[self.params2index[param_name]]
        else:
            raise LookupError('No parameter with name '+ param_name)

    def get_species_value(self, species_name):
        if species_name in self.species2index:
            return self.species_values[self.species2index[species_name]]
        else:
            raise LookupError('No species with name '+ species_name)

    def parse_general_expression(self, instring):
        return parse_expression(instring,self.species2index,self.params2index)

##################################################                ####################################################
######################################              SBML CONVERSION                     ##############################
#################################################                     ################################################

def _add_underscore_to_parameters(formula, parameters):
    sympy_rate = sympy.sympify(formula, _clash1)
    nodes = [sympy_rate]
    index = 0
    while index < len(nodes):
        node = nodes[index]
        index += 1
        nodes.extend(node.args)

    for node in nodes:
        if type(node) == sympy.Symbol:
            if node.name in parameters:
                node.name = '_' + node.name

    return str(sympy_rate)


def convert_sbml_to_string(sbml_file):
    """
    Convert a SBML model file to a BioSCRAPE compatible XML file. Note that events, compartments, non-standard
    function definitions, and rules that are not assignment rules are not supported. Furthermore, reversible
    reactions are highly not recommended, as they will mess up the simulator in stochastic mode.

    This function requires libsbml to be installed for Python. See sbml.org for help.

    :param sbml_file:(string) Name of the SBML file to read in from.
    :return:
    """
    out = ''

    # Attempt to import libsbml and read the model.
    try:
        import libsbml
    except:
        raise ImportError("libsbml not found. See sbml.org for installation help!\n" +
                          'If you are using anaconda you can run the following:\n' +
                          'conda install -c SBMLTeam python-libsbml\n\n\n')


    reader = libsbml.SBMLReader()
    doc = reader.readSBML(sbml_file)
    if doc.getNumErrors() > 1:
        raise SyntaxError('SBML File %s cannot be read without errors' % sbml_file)

    model = doc.getModel()

    # Add the top tag
    out += '<model>\n\n'

    # Parse through species and parameters and keep a set of both along with their values.
    allspecies = {}
    allparams = {}

    for s in model.getListOfSpecies():
        sid = s.getIdAttribute()
        if sid == "volume" or sid == "t":
            warnings.warn("You have defined a species called '" + sid +
                          ". This is being ignored and treated as a keyword.")
            continue
        allspecies[sid] = 0.0
        if np.isfinite(s.getInitialAmount()):
            allspecies[sid] = s.getInitialAmount()
        if np.isfinite(s.getInitialConcentration()) and allspecies[sid] == 0:
            allspecies[sid] = s.getInitialConcentration()

    for p in model.getListOfParameters():
        pid = p.getIdAttribute()
        allparams[pid] = 0.0
        if np.isfinite(p.getValue()):
            allparams[pid] = p.getValue()
    # Go through reactions one at a time to get stoich and rates.
    for reaction in model.getListOfReactions():
        # Warning message if reversible
        if reaction.getReversible():
            warnings.warn('Warning: SBML model contains reversible reaction!\n' +
                          'Please check rate expressions and ensure they are non-negative before doing '+
                          'stochastic simulations. This warning will always appear if you are using SBML 1 or 2')

        # Get the reactants and products
        reactant_list = []
        product_list = []

        for reactant in reaction.getListOfReactants():
            reactantspecies = reactant.getSpecies()
            if reactantspecies in allspecies:
                reactant_list.append(reactantspecies)
        for product in reaction.getListOfProducts():
            productspecies = product.getSpecies()
            if productspecies in allspecies:
                product_list.append(productspecies)

        out += ('<reaction text="%s--%s" after="--">\n' % ('+'.join(reactant_list),'+'.join(product_list)) )
        out +=  '    <delay type="none"/>\n'

        # get the propensity taken care of now
        kl = reaction.getKineticLaw()
        # capture any local parameters
        for p in kl.getListOfParameters():
            pid = p.getIdAttribute()
            allparams[pid] = 0.0
            if np.isfinite(p.getValue()):
                allparams[pid] = p.getValue()


        # get the formula as a string and then add
        # a leading _ to parameter names
        kl_formula = libsbml.formulaToL3String(kl.getMath())
        rate_string = _add_underscore_to_parameters(kl_formula,allparams)

        # Add the propensity tag and finish the reaction.
        out += ('    <propensity type="general" rate="%s" />\n</reaction>\n\n' % rate_string)

    # Go through rules one at a time
    for rule in model.getListOfRules():
        if rule.getElementName() != 'assignmentRule':
            warnings.warn('Unsupported rule type: %s' % rule.getElementName())
            continue
        rule_formula = libsbml.formulaToL3String(rule.getMath())
        rulevariable = rule.getVariable()
        if rulevariable in allspecies:
            rule_string = rulevariable + '=' + _add_underscore_to_parameters(rule_formula,allparams)
        elif rulevariable in allparams:
            rule_string = '_' + rulevariable + '=' + _add_underscore_to_parameters(rule_formula,allparams)
        else:
            warnings.warn('SBML: Attempting to assign something that is not a parameter or species %s'
                          % rulevariable)
            continue

        out += '<rule type="assignment" frequency="repeated" equation="%s" />\n' % rule_string

    # Check and warn if there are events
    if len(model.getListOfEvents()) > 0:
        warnings.warn('SBML model has events. They are being ignored!\n')


    # Go through species and parameter initial values.
    out += '\n'

    for s in allspecies:
        out += '<species name="%s" value="%.18E" />\n' % (s, allspecies[s])
    out += '\n'

    for p in allparams:
        out += '<parameter name="%s" value="%.18E"/>\n' % (p, allparams[p])

    out += '\n'

    # Add the final tag and return
    out += '</model>\n'
    return out

def read_model_from_sbml(sbml_file):
    model_string = convert_sbml_to_string(sbml_file)
    import io
    string_file = io.StringIO(model_string)
    return Model(string_file)




##################################################                ####################################################
######################################              DATA    TYPES                       ##############################
#################################################                     ################################################

cdef class Schnitz:
    def __init__(self, time, data, volume):
        """
        Create a Schnitz with the provided time, data, and volume arrays. Parents and daughters are left as None and
        must be set later if required.

        :param time: (np.ndarray) 1-D array with time points
        :param data: (np.ndarray) 2-D array with one row for each time point, one column for each measured output
        :param volume: (np.ndarray) 1-D array with volume at each time point
        """
        self.parent = None
        self.daughter1 = None
        self.daughter2 = None
        self.time = time
        self.volume = volume
        self.data = data

    def py_get_data(self):
        return self.data

    def py_set_data(self, data):
        self.data = data

    def py_get_time(self):
        return self.time

    def py_get_volume(self):
        return self.volume

    def py_get_parent(self):
        return self.parent

    def py_get_daughters(self):
        return (self.daughter1, self.daughter2)


    def py_set_parent(self, Schnitz p):
        self.set_parent(p)

    def py_set_daughters(self,Schnitz d1, Schnitz d2):
        self.set_daughters(d1,d2)


    def get_sub_lineage(self, dict species_dict = None):
        cdef Lineage out
        if species_dict is None:
            out = Lineage()
        else:
            out = ExperimentalLineage(species_dict.copy())


        cdef list schnitzes_to_add = [self]
        cdef unsigned index = 0
        cdef Schnitz s = None


        while index < len(schnitzes_to_add):
            s = schnitzes_to_add[index]
            if s.get_daughter_1() is not None:
                schnitzes_to_add.append(s.get_daughter_1())
            if s.get_daughter_2() is not None:
                schnitzes_to_add.append(s.get_daughter_2())

            index += 1

        for index in range(len(schnitzes_to_add)):
            out.add_schnitz(schnitzes_to_add[index])

        return out


    def copy(self):
        cdef Schnitz temp = Schnitz(self.time.copy(),self.data.copy(),self.volume.copy())
        temp.daughter1 = self.daughter1
        temp.daughter2 = self.daughter2
        temp.parent = self.parent
        return temp

    def __setstate__(self,state):
        self.parent = state[0]
        self.daughter1 = state[1]
        self.daughter2 = state[2]
        self.time = state[3]
        self.volume = state[4]
        self.data = state[5]

    def __getstate__(self):
        return (self.parent,self.daughter1,self.daughter2, self.time, self.volume, self.data)

cdef class Lineage:
    def __init__(self):
        """
        Creates a lineage object.
        """
        self.schnitzes = []

    def py_size(self):
        """
        Get the total number of schnitzes in the lineage.
        :return: (int) size of lineage
        """
        return self.c_schnitzes.size()

    def py_get_schnitz(self, unsigned index):
        """
        Get a specific schnitz from the lineage
        :param index: (unsigned) the Schnitz to retrieve 0 <= index < size()
        :return: (Schnitz) the requested Schnitz
        """
        return (<Schnitz> (self.c_schnitzes[index]))

    def py_add_schnitz(self, Schnitz s):
        self.add_schnitz(s)

    def __setstate__(self, state):
        self.schnitzes = []
        self.c_schnitzes.clear()
        for s in state[0]:
            self.add_schnitz(s)

    def __getstate__(self):
        return (self.schnitzes,)

    def truncate_lineage(self,double start_time, double end_time):
        cdef Schnitz sch, new_sch
        cdef dict sch_dict = {}
        cdef Lineage new_lineage = Lineage()
        cdef np.ndarray newtime, newvolume, newdata, indices_to_keep

        sch_dict[None] = None
        for i in range(self.size()):
            sch = self.get_schnitz(i)

            newtime = sch.get_time().copy()
            newvolume = sch.get_volume().copy()
            newdata = sch.get_data().copy()

            # if the final time of this lineage is before the starting time
            # or the first time is before the end time, then skip it
            if newtime[newtime.shape[0]-1] < start_time or newtime[0] > end_time:
                sch_dict[sch] = None
                continue

            indices_to_keep = (sch.get_time() >= start_time) & (sch.get_time() <= end_time)
            newtime = newtime[indices_to_keep]
            newvolume = newvolume[indices_to_keep]
            newdata = newdata[indices_to_keep]

            sch_dict[sch] = Schnitz(newtime, newdata, newvolume)

        for i in range(self.size()):
            sch = self.get_schnitz(i)
            if sch_dict[sch] is not None:
                new_lineage.add_schnitz(sch_dict[sch])
                sch_dict[sch].py_set_parent( sch_dict[sch.get_parent()] )
                sch_dict[sch].py_set_daughters( sch_dict[sch.get_daughter_1()] , sch_dict[sch.get_daughter_2()] )

        return new_lineage

cdef class ExperimentalLineage(Lineage):
    def __init__(self, dict species_indices={}):
        super().__init__()
        self.species_dict = species_indices

    def py_set_species_indices(self, dict species_indices):
        self.species_dict = species_indices.copy()

    def py_get_species_index(self, str species):
        if species in self.species_dict:
            return self.species_dict[species]
        warnings.warn('Species not found in experimental lineage: %s\n' % species)
        return -1

    def __setstate__(self, state):
        super().__setstate__(state[:len(state)-1])
        self.species_dict = state[len(state)-1]

    def __getstate__(self):
        return super().__getstate__() + (self.species_dict,)

    def truncate_lineage(self,double start_time, double end_time):
        cdef Schnitz sch, new_sch
        cdef dict sch_dict = {}
        cdef ExperimentalLineage new_lineage = ExperimentalLineage()
        cdef np.ndarray newtime, newvolume, newdata, indices_to_keep

        sch_dict[None] = None
        for i in range(self.size()):
            sch = self.get_schnitz(i)

            newtime = sch.get_time().copy()
            newvolume = sch.get_volume().copy()
            newdata = sch.get_data().copy()

            # if the final time of this lineage is before the starting time
            # or the first time is before the end time, then skip it
            if newtime[newtime.shape[0]-1] < start_time or newtime[0] > end_time:
                sch_dict[sch] = None
                continue

            indices_to_keep = (sch.get_time() >= start_time) & (sch.get_time() <= end_time)
            newtime = newtime[indices_to_keep]
            newvolume = newvolume[indices_to_keep]
            newdata = newdata[indices_to_keep]

            sch_dict[sch] = Schnitz(newtime, newdata, newvolume)

        for i in range(self.size()):
            sch = self.get_schnitz(i)
            if sch_dict[sch] is not None:
                new_lineage.add_schnitz(sch_dict[sch])
                sch_dict[sch].py_set_parent( sch_dict[sch.get_parent()] )
                sch_dict[sch].py_set_daughters( sch_dict[sch.get_daughter_1()] , sch_dict[sch.get_daughter_2()] )

        new_lineage.py_set_species_indices(self.species_dict.copy())

        return new_lineage










