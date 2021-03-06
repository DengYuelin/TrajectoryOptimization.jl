abstract type AbstractExpansion{T} end

struct GradientExpansion{T,N,M} <: AbstractExpansion{T}
	x::SizedVector{N,T,Vector{T}}
	u::SizedVector{M,T,Vector{T}}
	function GradientExpansion{T}(n::Int,m::Int) where T
		new{T,n,m}(SizedVector{n}(zeros(T,n)), SizedVector{m}(zeros(T,m)))
	end
end

struct QExpansionMC#{T,N,M,P} <: AbstractExpansion{T}
	x
	u
	λ
	ux
	uu
	uλ
	xx
	xu
	xλ
	λx
	λu
	λλ
end

# TODO: Move to ALTRO

abstract type GeneralDynamicsExpansion end

"""
	DynamicsExpansion{T,N,N̄,M}

Stores the dynamics expansion for a single time instance. 
For a `LieGroupModel`, it will provide access to both the state and state
error Jacobians.

# Constructors
```julia
DynamicsExpansion{T}(n0, n, m)
DynamicsExpansion{T}(n, m)
```
where `n0` is the size of the full state, and `n` is the size of the error state.

# Methods
To evaluate the dynamics Jacobians, use

	dynamics_expansion!(::Type{Q}, D::DynamicsExpansion, model, Z)

To compute the Jacobians for the error state, use
	
	error_expansion!(D::DynamicsExpansion, model, G)

where `G` is a vector of error-state Jacobians. These can be computed using
`RobotDynamics.state_diff_jacobian(G, model, Z)`.

# Extracting Jacobians
The Jacobians should be extracted using

	fdx, fdu = error_expansion(D::DynamicsExpansion, model)

This method will provide the error state Jacobians for `LieGroupModel`s, and 
	the normal Jacobian otherwise. Both `fdx` and `fdu` are a `SizedMatrix`.
"""
struct DynamicsExpansion{T,N,N̄,M} <: GeneralDynamicsExpansion
	∇f::Matrix{T} # n × (n+m)
	∇²f::Matrix{T}  # (n+m) × (n+m)
	A_::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
	B_::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
	A::SizedMatrix{N̄,N̄,T,2,Matrix{T}}
	B::SizedMatrix{N̄,M,T,2,Matrix{T}}
	fxx::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
	fuu::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
	fux::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
	tmpA::SizedMatrix{N,N,T,2,Matrix{T}}
	tmpB::SizedMatrix{N,M,T,2,Matrix{T}}
	tmp::SizedMatrix{N,N̄,T,2,Matrix{T}}
	function DynamicsExpansion{T}(n0::Int, n::Int, m::Int) where T
		∇f = zeros(n0,n0+m)
		∇²f = zeros(n0+m,n0+m)
		ix = 1:n0
		iu = n0 .+ (1:m)
		A_ = view(∇f, ix, ix)
		B_ = view(∇f, ix, iu)
		A = SizedMatrix{n,n}(zeros(n,n))
		B = SizedMatrix{n,m}(zeros(n,m))
		fxx = view(∇²f, ix, ix)
		fuu = view(∇²f, iu, iu)
		fux = view(∇²f, iu, ix)
		tmpA = SizedMatrix{n0,n0}(zeros(n0,n0))
		tmpB = SizedMatrix{n0,m}(zeros(n0,m))
		tmp = zeros(n0,n)
		new{T,n0,n,m}(∇f,∇²f,A_,B_,A,B,fxx,fuu,fux,tmpA,tmpB,tmp)
	end
	function DynamicsExpansion{T}(n::Int, m::Int) where T
		∇f = zeros(n,n+m)
		∇²f = zeros(n+m,n+m)
		ix = 1:n
		iu = n .+ (1:m)
		A_ = view(∇f, ix, ix)
		B_ = view(∇f, ix, iu)
		A = SizedMatrix{n,n}(zeros(n,n))
		B = SizedMatrix{n,m}(zeros(n,m))
		fxx = view(∇²f, ix, ix)
		fuu = view(∇²f, iu, iu)
		fux = view(∇²f, iu, ix)
		tmpA = A
		tmpB = B
		tmp = zeros(n,n)
		new{T,n,n,m}(∇f,∇²f,A_,B_,A,B,fxx,fuu,fux,tmpA,tmpB,tmp)
	end
end


function save_tmp!(D::DynamicsExpansion)
	D.tmpA .= D.A_
	D.tmpB .= D.B_
end

function dynamics_expansion!(Q, D::Vector{<:DynamicsExpansion}, model::AbstractModel,
		Z::Traj)
	for k in eachindex(D)
		RobotDynamics.discrete_jacobian!(Q, D[k].∇f, model, Z[k])
		# save_tmp!(D[k])
		# D[k].tmpA .= D[k].A_  # avoids allocations later
		# D[k].tmpB .= D[k].B_
	end
end

# function dynamics_expansion!(D::Vector{<:DynamicsExpansion}, model::AbstractModel,
# 		Z::Traj, Q=RobotDynamics.RK3)
# 	for k in eachindex(D)
# 		RobotDynamics.discrete_jacobian!(Q, D[k].∇f, model, Z[k])
# 		D[k].tmpA .= D[k].A_  # avoids allocations later
# 		D[k].tmpB .= D[k].B_
# 	end
# end


function error_expansion!(D::DynamicsExpansion,G1,G2)
    mul!(D.tmp, D.tmpA, G1)
    mul!(D.A, Transpose(G2), D.tmp)
    mul!(D.B, Transpose(G2), D.tmpB)
end

@inline error_expansion(D::DynamicsExpansion, model::LieGroupModel) = D.A, D.B
@inline error_expansion(D::DynamicsExpansion, model::AbstractModel) = D.tmpA, D.tmpB

@inline DynamicsExpansion(model::AbstractModel) = DynamicsExpansion{Float64}(model)
@inline function DynamicsExpansion{T}(model::AbstractModel) where T
	n,m = size(model)
	n̄ = state_diff_size(model)
	DynamicsExpansion{T}(n,n̄,m)
end



function error_expansion!(D::Vector{<:DynamicsExpansion}, model::AbstractModel, G)
	for d in D
		save_tmp!(d)
	end
end

function error_expansion!(D::Vector{<:DynamicsExpansion}, model::LieGroupModel, G)
	for k in eachindex(D)
		save_tmp!(D[k])
		error_expansion!(D[k], G[k], G[k+1])
	end
end

# function linearize(::Type{Q}, model::AbstractModel, z::AbstractKnotPoint) where Q
# 	D = DynamicsExpansion(model)
# 	linearize!(Q, D, model, z)
# end
#
# function linearize!(::Type{Q}, D::DynamicsExpansion{<:Any,<:Any,N,M}, model::AbstractModel,
# 		z::AbstractKnotPoint) where {N,M,Q}
# 	discrete_jacobian!(Q, D.∇f, model, z)
# 	D.tmpA .= D.A_  # avoids allocations later
# 	D.tmpB .= D.B_
# 	return D.tmpA, D.tmpB
# end
#
# function linearize!(::Type{Q}, D::DynamicsExpansion, model::LieGroupModel) where Q
# 	discrete_jacobian!(Q, D.∇f, model, z)
# 	D.tmpA .= D.A_  # avoids allocations later
# 	D.tmpB .= D.B_
# 	G1 = state_diff_jacobian(model, state(z))
# 	G2 = state_diff_jacobian(model, x1)
# 	error_expansion!(D, G1, G2)
# 	return D.A, D.B
# end



"""
	
DynamicsExpansionMC{T,N,N̄,M,P}

Note: this is a very early implementation without thorough design thinking
Stores the dynamics expansion for a single time instance for a system represented in maximal coordinate
Originally we thought we could just expand DynamicsExpansion by adding more 
matrices, however the size of additional matrices are pretty different 

{T,N,N̄,M}
 T  data type
 N  size of state 
 N̄  size of the error state (in case the state has Lie group elements)
 M  size of the control
 P  size of the constraint force
"""

# mutable struct DynamicsExpansionMC{T,N,N̄,M,P} <: GeneralDynamicsExpansion
# 	A::SizedMatrix{N̄,N̄,T,2,Matrix{T}}  # nxn
# 	B::SizedMatrix{N̄,M,T,2,Matrix{T}}  # nxm
# 	C::SizedMatrix{N̄,P,T,2,Matrix{T}}  # nxp
# 	G::SizedMatrix{P,N̄,T,2,Matrix{T}}  # pxn

# 	function DynamicsExpansionMC{T}(n::Int, m::Int, p::Int) where T
# 		A = SizedMatrix{n,n}(zeros(n,n))
# 		B = SizedMatrix{n,m}(zeros(n,m))
# 		C = SizedMatrix{n,p}(zeros(n,p))
# 		G = SizedMatrix{p,n}(zeros(p,n))
# 		new{T,n,n,m,p}(A,B,C,G)

# 	end

# end

mutable struct DynamicsExpansionMC{T,N,N̄,M,P} <: GeneralDynamicsExpansion
∇f::Matrix{T} # n × (n+m)
A_::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
B_::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
C_::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
A::SizedMatrix{N̄,N̄,T,2,Matrix{T}}
B::SizedMatrix{N̄,M,T,2,Matrix{T}}
C::SizedMatrix{N̄,P,T,2,Matrix{T}}
tmpA::SizedMatrix{N,N,T,2,Matrix{T}}
tmpB::SizedMatrix{N,M,T,2,Matrix{T}}
tmpC::SizedMatrix{N,P,T,2,Matrix{T}}
tmp::SizedMatrix{N,N̄,T,2,Matrix{T}}
G::SizedMatrix{P,N̄,T,2,Matrix{T}}  # pxn
all_partials::Matrix{T}
function DynamicsExpansionMC{T}(n0::Int, n::Int, m::Int, p::Int) where T
    ∇f = zeros(n0,n0+m+p)
    ix = 1:n0
    iu = n0 .+ (1:m)
    iλ = (n0+m) .+ (1:p)
    A_ = view(∇f, ix, ix)
    B_ = view(∇f, ix, iu)
    C_ = view(∇f, ix, iλ)
    A = SizedMatrix{n,n}(zeros(n,n))
    B = SizedMatrix{n,m}(zeros(n,m))
    C = SizedMatrix{n,p}(zeros(n,p))
    tmpA = SizedMatrix{n0,n0}(zeros(n0,n0))
    tmpB = SizedMatrix{n0,m}(zeros(n0,m))
    tmpC = SizedMatrix{n0,p}(zeros(n0,p))
    tmp = zeros(n0,n)
    G = SizedMatrix{p,n}(zeros(p,n))
	all_partials = zeros(n0, 2n0+m+p)
    new{T,n0,n,m,p}(∇f,A_,B_,C_,A,B,C,tmpA,tmpB,tmpC,tmp,G,all_partials)
end
function DynamicsExpansionMC{T}(n::Int, m::Int, p::Int) where T
    DynamicsExpansionMC{T}(n, n, m, p)
end
end