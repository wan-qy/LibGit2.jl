export Repository, repo_isbare, repo_isempty, repo_workdir, repo_path, path,
       repo_open, repo_init, repo_index, head, set_head!, tags, tag!, commits, references,
       repo_lookup, lookup_tree, lookup_commit, commit, ref_names,
       repo_revparse_single, create_ref, create_sym_ref, lookup_ref,
       repo_odb, iter_refs, config, repo_treebuilder, TreeBuilder,
       insert!, write!, close, lookup, rev_parse, rev_parse_oid, remotes,
       ahead_behind, merge_base, oid, blob_at, is_shallow, hash_data,
       default_signature, repo_discover, is_bare, is_empty, namespace, set_namespace!,
       notes, create_note!, remove_note!, each_note, note_default_ref, iter_notes,
       blob_from_buffer, blob_from_workdir, blob_from_disk,
       branch_names, lookup_branch, create_branch, lookup_remote, iter_branches,
       remote_names

type Repository
    ptr::Ptr{Void}
    
    function Repository(ptr::Ptr{Void}, manage::Bool=true)
        if ptr == C_NULL
            throw(ArgumentError("Repository initialized with NULL pointer"))
        end
        r = new(ptr)
        if manage
            finalizer(r, free!)
        end
        return r
    end
end

free!(r::Repository) = begin
    if r.ptr != C_NULL
        close(r)
        api.git_repository_free(r.ptr)
        r.ptr = C_NULL
    end
end

Repository(path::String; alternates=nothing) = begin
    bpath = bytestring(path)
    repo_ptr = Array(Ptr{Void}, 1)
    err_code = api.git_repository_open(repo_ptr, bpath)
    if err_code < 0
        if repo_ptr[1] != C_NULL
            api.git_repository_free(repo_ptr[1])
        end
        throw(GitError(err_code))
    end
    @check_null repo_ptr
    repo = Repository(repo_ptr[1])
    if alternates != nothing && length(alternates) > 0
        odb = repo_odb(repo)
        for path in alternates
            if !isdir(path)
                throw(ArgumentError("alternate $path is not a valid dir"))
            end
            bpath = bytestring(path)
            err = api.git_odb_add_disk_alternate(odb.ptr, bpath)
            if err != api.GIT_OK
                throw(GitError(err))
            end
        end
    end
    return repo
end

Base.close(r::Repository) = begin
    if r.ptr != C_NULL
        api.git_repository__cleanup(r.ptr)
    end
end

Base.in(id::Oid, r::Repository) = begin
    odb = repo_odb(r)
    return exists(odb, id)::Bool
end

function cb_iter_oids(idptr::Ptr{Uint8}, o::Ptr{Void})
    try
        produce(Oid(idptr))
        return api.GIT_OK
    catch err
        return api.ERROR
    end
end

const c_cb_iter_oids = cfunction(cb_iter_oids, Cint, (Ptr{Uint8}, Ptr{Void}))

#TODO: better error handling
Base.start(r::Repository) = begin
    odb = repo_odb(r)
    t = @task api.git_odb_foreach(odb.ptr, c_cb_iter_oids, C_NULL)
    (consume(t), t)
end

Base.done(r::Repository, state) = begin
    istaskdone(state[2])
end

Base.next(r::Repository, state) = begin
    v = consume(state[2])
    (state[1], (v, state[2]))
end

Base.read(r::Repository, id::Oid) = begin
    odb = repo_odb(r)
    obj_ptr = Array(Ptr{Void}, 1)
    @check api.git_odb_read(obj_ptr, odb.ptr, id.oid)
    @check_null obj_ptr
    return OdbObject(obj_ptr[1])
end

Base.delete!(r::Repository, ref::GitReference) = begin
    @assert r.ptr != C_NULL && ref.ptr != C_NULL
    @check api.git_reference_delete(ref.ptr)
    return r
end

Base.delete!(r::Repository, t::GitTag) = begin
    @assert r.ptr != C_NULL && t.ptr != C_NULL
    @check api.git_tag_delete(r.ptr, name(t))
    return nothing
end

function read_header(r::Repository, id::Oid)
    odb = repo_odb(r)
    return read_header(odb, id)
end

exists(r::Repository, id::Oid) = id in r 

exists(r::Repository, ref::String) = begin
    @assert r.ptr != C_NULL
    ref_ptr = Array(Ptr{Void}, 1)
    err = api.git_reference_lookup(ref_ptr, r.ptr, bytestring(ref))
    api.git_reference_free(ref_ptr[1])
    if err == api.ENOTFOUND
        return false
    elseif err != api.GIT_OK
        throw(GitError(err))
    end
    return true
end

        
@deprecate repo_isbare is_bare
repo_isbare(r::Repository) = is_bare(r)

function is_bare(r::Repository)
    @assert r.ptr != C_NULL
    res = api.git_repository_is_bare(r.ptr)
    return res > zero(Cint) ? true : false
end

@deprecate repo_isbare is_bare
repo_isempty(r) = is_empty(r)

function is_empty(r::Repository)
    @assert r.ptr != C_NULL
    res = api.git_repository_is_empty(r.ptr) 
    return res > zero(Cint) ? true : false
end

function is_shallow(r::Repository)
    @assert r.ptr != C_NULL
    res = api.git_repository_is_shallow(r.ptr)
    return res > zero(Cint) ? true : false
end

function repo_workdir(r::Repository)
    @assert r.ptr != C_NULL
    res = api.git_repository_workdir(r.ptr)
    if res == C_NULL
        return nothing
    end
    # remove trailing slash
    return bytestring(res)[1:end-1]
end

@deprecate repo_path path
repo_path(r::Repository) = path(r)

function path(r::Repository)
    @assert r.ptr != C_NULL
    cpath = api.git_repository_path(r.ptr)
    if cpath == C_NULL
        return nothing
    end
    # remove trailing slash
    return bytestring(cpath)[1:end-1]
end

function hash_data{T<:GitObject}(::Type{T}, content::String)
    out = Oid()
    bcontent = bytestring(content)
    @check api.git_odb_hash(out.oid, bcontent, length(bcontent), git_otype(T))
    return out
end

function default_signature(r::Repository)
    @assert r.ptr != C_NULL
    sig_ptr = Array(Ptr{api.GitSignature}, 1)
    err = api.git_signature_default(sig_ptr, r.ptr)
    if err == api.ENOTFOUND
        return nothing
    elseif err != api.GIT_OK
        throw(GitError(err))
    end
    @check_null sig_ptr 
    gsig = unsafe_load(sig_ptr[1])
    sig = Signature(gsig)
    api.free!(gsig)
    return sig
end

function repo_head_orphaned(r::Repository)
end

function repo_head_detached(r::Repository)
end

function repo_open(path::String)
    Repository(path)
end

function repo_init(path::String; bare::Bool=false)
    bpath = bytestring(path)
    repo_ptr = Array(Ptr{Void}, 1)
    err_code = api.git_repository_init(repo_ptr, bpath, bare? 1 : 0)
    if err_code < 0
        if repo_ptr[1] != C_NULL
            api.git_repository_free(repo_ptr[1])
        end
        throw(GitError(err_code))
    end
    @check_null repo_ptr
    return Repository(repo_ptr[1])
end


function repo_clone(url::String; 
                    repobare::Bool=false,
                    ignore_cert_errors::Bool=false,
                    remote_name::String="origin",
                    checkout_branch=nothing)
end


function set_namespace!(r::Repository, ns)
    if ns == nothing || isempty(ns)
        @check api.git_repository_set_namespace(r.ptr, C_NULL)
    else
        @check api.git_repository_set_namespace(r.ptr, bytestring(ns))
    end
    return r
end

function namespace(r::Repository)
    ns_ptr = api.git_repository_get_namespace(r.ptr)
    if ns_ptr == C_NULL
        return nothing
    end
    return bytestring(ns_ptr)
end

function head(r::Repository)
    @assert r.ptr != C_NULL
    head_ptr = Array(Ptr{Void}, 1)
    err = api.git_repository_head(head_ptr, r.ptr)
    if err == api.ENOTFOUND || err == api.EUNBORNBRANCH
        return nothing
    elseif err != api.GIT_OK
        throw(GitError(err))
    end 
    @check_null head_ptr
    return GitReference(head_ptr[1])
end

oid(r::Repository, val::GitObject) = oid(val)
oid(r::Repository, val::Oid) = val

function oid(r::Repository, val::String)
    if length(val) == api.OID_HEXSZ
        try
            return Oid(val)
        catch
        end
    end
    return oid(rev_parse(r, val))
end
        
function set_head!(r::Repository, ref::String)
    @assert r.ptr != C_NULL
    @check api.git_repository_set_head(r.ptr, bytestring(ref))
    return r
end

function commits(r::Repository)
    return nothing 
end

function remotes(r::Repository)
    @assert r.ptr != C_NULL
    rs = api.GitStrArray()
    @check ccall((:git_remote_list, api.libgit2), Cint,
                 (Ptr{api.GitStrArray}, Ptr{Void}),
                 &rs, r.ptr)
    if rs.count == 0 
        return nothing 
    end
    remote_ptr = Array(Ptr{Void}, 1)
    out = Array(GitRemote, rs.count)
    for i in 1:rs.count 
        rstr = bytestring(unsafe_load(rs.strings, i))
        @check api.git_remote_load(remote_ptr, r.ptr, rstr)
        @check_null remote_ptr
        out[i] = GitRemote(remote_ptr[1])
    end
    return out
end

#TODO: this should be moved to remote
GitRemote(r::Repository, url::String) = begin
    @assert r.ptr != C_NULL
    check_valid_url(url)
    remote_ptr = Array(Ptr{Void}, 1)
    @check api.git_remote_create_inmemory(remote_ptr, r.ptr, C_NULL, bytestring(url))
    @check_null remote_ptr
    return GitRemote(remote_ptr[1])
end

#TODO: this is redundant with above function
function remote_names(r::Repository)
    @assert r.ptr != C_NULL
    rs = api.GitStrArray()
    @check ccall((:git_remote_list, api.libgit2), Cint,
                  (Ptr{api.GitStrArray}, Ptr{Void}),
                  &rs, r.ptr)
    ns = Array(String, rs.count)
    for i in 1:rs.count
        ns[i] = bytestring(unsafe_load(rs.strings, i))
    end
    return ns
end

function lookup(::Type{GitRemote}, r::Repository, remote_name::String)
    @assert r.ptr != C_NULL
    remote_ptr =  Array(Ptr{Void}, 1)
    err = api.git_remote_load(remote_ptr, r.ptr, bytestring(remote_name))
    if err == api.ENOTFOUND
        return nothing
    elseif err != api.GIT_OK
        throw(GitError(err))
    end
    @check_null remote_ptr
    return GitRemote(remote_ptr[1])
end

lookup_remote(r::Repository, remote_name::String) = lookup(GitRemote, r, remote_name)

function tags(r::Repository, glob=nothing)
    @assert r.ptr != C_NULL
    local cglob::ByteString
    if glob != nothing
        cglob = bytestring(glob)
    else
        cglob = bytestring("") 
    end
    gittags = api.GitStrArray()
    @check ccall((:git_tag_list_match, api.libgit2), Cint,
                 (Ptr{api.GitStrArray}, Ptr{Cchar}, Ptr{Void}),
                 &gittags, cglob, r.ptr)
    if gittags.count == 0
        return nothing
    end
    out = Array(ASCIIString, gittags.count)
    for i in 1:gittags.count
        cptr = unsafe_load(gittags.strings, i)
        out[i] = bytestring(cptr)
    end
    return out
end

function tag!(r::Repository; 
              name::String="",
              message::String="",
              target::Union(Nothing,Oid)=nothing,
              tagger::Union(Nothing,Signature)=nothing,
              force::Bool=false)
   @check r.ptr != C_NULL
   if target != nothing
       obj = lookup(r, target)
   end
   tid = Oid()
   if !isempty(message)
       if tagger != nothing
           gsig = git_signature(tagger)
       else
           gsig = git_signature(default_signature(r))
       end
       @check ccall((:git_tag_create, api.libgit2), Cint,
                    (Ptr{Uint8}, Ptr{Void}, Ptr{Cchar},
                     Ptr{Void}, Ptr{api.GitSignature}, Ptr{Cchar}, Cint),
                     tid.oid, r.ptr, bytestring(name), obj.ptr, 
                     &gsig, bytestring(message), force)
   else
       @check api.git_tag_create_lightweight(tid.oid,
                                             r.ptr,
                                             bytestring(name),
                                             obj.ptr,
                                             force? 1 : 0)
   end
   return tid
end

function create_note!(
               obj::GitObject, msg::String; 
               committer::Union(Nothing, Signature)=nothing,
               author::Union(Nothing, Signature)=nothing,
               ref::Union(Nothing, String)=nothing,
               force::Bool=false)
    @assert obj.ptr != nothing
    #repo = Repository(api.git_object_owner(obj.ptr))
    repo_ptr = api.git_object_owner(obj.ptr)
    target_id = oid(obj)
    bref = ref != nothing ? bytestring(ref) : C_NULL
    if committer != nothing
        committer_ptr = git_signature_ptr(committer)
    else
        # gcommitter = git_signature(default_signature(repo))
        sig_ptr = Array(Ptr{api.GitSignature}, 1)
        api.git_signature_default(sig_ptr, repo_ptr)
        committer_ptr = sig_ptr[1]
 
    end
    if author != nothing
        author_ptr = git_signature_ptr(author)
    else
        # gauthor = git_signature(default_signature(repo))
        sig_ptr = Array(Ptr{api.GitSignature}, 1)
        api.git_signature_default(sig_ptr, repo_ptr)
        author_ptr = sig_ptr[1]
    end
    note_id  = Oid()
    @check ccall((:git_note_create, api.libgit2), Cint,
                 (Ptr{Uint8}, Ptr{Void}, Ptr{api.GitSignature},
                  Ptr{api.GitSignature}, Ptr{Cchar}, Ptr{Uint8},
                  Ptr{Cchar}, Cint),
                 note_id.oid, repo_ptr, committer_ptr, author_ptr,
                 bref, target_id.oid, bytestring(msg),
                 force? 1 : 0)
    return note_id
end

function remove_note!(obj::GitObject;
                      committer::Union(Nothing,Signature)=nothing,
                      author::Union(Nothing,Signature)=nothing,
                      ref::Union(Nothing,String)=nothing)
    @assert obj.ptr != C_NULL
    target_id = oid(obj)
    #repo = Repository(api.git_object_owner(obj.ptr))
    repo_ptr = api.git_object_owner(obj.ptr)
    notes_ref = ref != nothing ? bytestring(ref) : bytestring("refs/notes/commits")
    if committer != nothing
        committer_ptr = git_signature_ptr(committer)
    else
        sig_ptr = Array(Ptr{api.GitSignature}, 1)
        api.git_signature_default(sig_ptr, repo_ptr)
        committer_ptr = sig_ptr[1]
        #gcommitter = git_signature(default_signature(repo))
    end
    if author != nothing
        author_ptr = git_signature_ptr(author)
    else
        #gauthor = git_signature(default_signature(repo))
        sig_ptr = Array(Ptr{api.GitSignature}, 1)
        api.git_signature_default(sig_ptr, repo_ptr)
        author_ptr = sig_ptr[1]
    end 
    err = ccall((:git_note_remove, api.libgit2), Cint,
                (Ptr{Void}, Ptr{Cchar}, 
                 Ptr{api.GitSignature}, Ptr{api.GitSignature}, Ptr{Uint8}),
                 repo_ptr, notes_ref, author_ptr, committer_ptr, target_id.oid)
    if err == api.ENOTFOUND
        return false
    elseif err != api.GIT_OK
        throw(GitError(err))
    end
    return true
end

function note_default_ref(r::Repository)
    refname_ptr = Array(Ptr{Cchar}, 1)
    @check api.git_note_default_ref(refname_ptr, r.ptr)
    return bytestring(refname_ptr[1])
end

# todo the following should be moved to not    
function notes(obj::GitObject, ref=nothing)
    lookup_note(obj, ref)
end

function lookup_note(obj::GitObject, ref=nothing)
    if ref == nothing
        bref = C_NULL
    else 
        bref = bytestring(ref)
    end
    note_ptr = Array(Ptr{Void}, 1)
    repo_ptr = api.git_object_owner(obj.ptr)
    err = api.git_note_read(note_ptr, repo_ptr, bref, oid(obj).oid)
    if err == api.ENOTFOUND
        return nothing
    elseif err != api.GIT_OK
        throw(GitError(err))
    end
    @check_null note_ptr
    n = GitNote(note_ptr[1])
    api.git_note_free(note_ptr[1])
    return n
end

function cb_iter_notes(blob_id::Ptr{Uint8}, ann_obj_id::Ptr{Uint8}, repo_ptr::Ptr{Void})
    ann_obj_ptr = Array(Ptr{Void}, 1)
    blob_ptr = Array(Ptr{Void}, 1)
    err = api.git_object_lookup(ann_obj_ptr, repo_ptr, ann_obj_id, api.OBJ_BLOB)
    err |= api.git_object_lookup(blob_ptr, repo_ptr, blob_id, api.OBJ_BLOB)
    if err == api.GIT_OK
        res = (gitobj_from_ptr(ann_obj_id[1]), 
               gitobj_from_ptr(blob_ptr[1]))
        produce(res)
    end
    return err
end

const c_cb_iter_notes = cfunction(cb_iter_notes, Cint, (Ptr{Uint8}, Ptr{Uint8}, Ptr{Void}))

function iter_notes(r::Repository, notes_ref=nothing)
    @assert r.ptr != C_NULL
    if ref == nothing
        bnotes_ref = C_NULL
    else
        bnotes_ref = bytestring(notes_ref)
    end
    return @task api.git_note_foreach(r.ptr, notes_ref, c_cb_iter_notes, r.ptr)
end

function ahead_behind(r::Repository,
                      lcommit::GitCommit,
                      ucommit::GitCommit)
    ahead_behind(r, oid(lcommit), oid(ucommit))
end

function ahead_behind(r::Repository, lid::Oid, uid::Oid)
    @assert r.ptr != C_NULL
    ahead = Csize_t[0]
    behind = Csize_t[0]
    @check api.git_graph_ahead_behind(
                ahead, behind, r.ptr, lid.oid, uid.oid)
    return (int(ahead[1]), int(behind[1]))
end

function blob_at(r::Repository, rev::Oid, p::String)
    tree = git_tree(lookup_commit(r, rev))
    local blob_entry::GitTreeEntry
    try
        blob_entry = entry_bypath(tree, p)
        @assert isa(blob_entry, GitTreeEntry{GitBlob})
    catch
        return nothing
    end
    blob = lookup_blob(r, oid(blob_entry))
    return blob
end

function blob_from_buffer(r::Repository, buf::ByteString)
    @assert  r.ptr != C_NULL
    blob_id = Oid()
    @check api.git_blob_create_frombuffer(blob_id.oid, r.ptr, buf, length(buf))
    return blob_id
end

function blob_from_workdir(r::Repository, path::String)
    @assert r.ptr != C_NULL
    blob_id = Oid()
    @check api.git_blob_create_fromworkdir(blob_id.oid, r.ptr, bytestring(path))
    return blob_id
end

function blob_from_disk(r::Repository, path::String)
    @assert r.ptr != C_NULL
    blob_id = Oid()
    @check api.git_blob_create_fromdisk(blob_id.oid, r.ptr, bytestring(path))
    return blob_id
end


#TODO: consolidate with odb
function write!{T<:GitObject}(::Type{T}, r::Repository, buf::ByteString)
    @assert r.ptr != C_NULL
    odb = repo_odb(r)
    gty = git_otype(T)
    stream_ptr = Array(Ptr{Void}, 1) 
    @check api.git_odb_open_wstream(stream_ptr, odb.ptr, length(buf), gty)
    err = api.git_odb_stream_write(stream_ptr[1], buf, length(buf))
    out = Oid()
    if !(bool(err))
        err = api.git_odb_stream_finalize_write(out.oid, stream_ptr[1])
    end
    api.git_odb_stream_free(stream_ptr[1])
    if err != api.GIT_OK
        throw(GitError(err))
    end
    return out
end

function references(r::Repository)
    return nothing
end


function repo_discover(p::String="", acrossfs::Bool=true)
    if isempty(p); p = pwd(); end
    brepo = Array(Cchar, api.GIT_PATH_MAX)
    bp = bytestring(p)
    @check api.git_repository_discover(brepo, api.GIT_PATH_MAX, 
                                       bp, acrossfs? 1 : 0, C_NULL)
    return Repository(bytestring(convert(Ptr{Cchar}, brepo)))
end

function rev_parse(r::Repository, rev::String)
    @assert r.ptr != C_NULL
    brev = bytestring(rev)
    obj_ptr = Array(Ptr{Void}, 1)
    @check api.git_revparse_single(obj_ptr, r.ptr, brev)
    @check_null obj_ptr
    obj = gitobj_from_ptr(obj_ptr[1]) 
    return obj
end

function rev_parse(r::Repository, rev::Oid)
    return rev_parse(r, string(rev))
end

function merge_base(r::Repository, args...)
    @assert r.ptr != C_NULL
    if length(args) < 2
        throw(ArgumentError("merge_base needs 2+ commits"))
    end
    arg_oids = vcat([raw(oid(r, a)) for a in args]...)
    @assert length(arg_oids) == length(args) * api.OID_RAWSZ
    len = convert(Csize_t, length(args))
    id = Oid()
    err = api.git_merge_base_many(id.oid, r.ptr, len, arg_oids)
    if err == api.ENOTFOUND
        return nothing
    elseif err != api.GIT_OK
        throw(GitError(err))
    end
    return id
end
    
function rev_parse_oid(r::Repository, rev::String)
    oid(rev_parse(r::Repository, rev::String))
end

function config(r::Repository)
    @assert r.ptr != C_NULL
    config_ptr = Array(Ptr{Void}, 1)
    @check api.git_repository_config(config_ptr, r.ptr)
    @check_null config_ptr
    return GitConfig(config_ptr[1])
end

function repo_odb(r::Repository)
    @assert r.ptr != C_NULL
    odb_ptr = Array(Ptr{Void}, 1)
    @check api.git_repository_odb(odb_ptr, r.ptr)
    @check_null odb_ptr
    return Odb(odb_ptr[1])
end

function repo_index(r::Repository)
    @assert r.ptr != C_NULL
    idx_ptr = Array(Ptr{Void}, 1)
    @check api.git_repository_index(idx_ptr, r.ptr)
    @check_null idx_ptr
    return GitIndex(idx_ptr[1])
end

function lookup{T<:GitObject}(::Type{T}, r::Repository, id::Oid)
    @assert r.ptr != C_NULL
    obj_ptr = Array(Ptr{Void}, 1)
    @check api.git_object_lookup(obj_ptr, r.ptr, id.oid, git_otype(T))
    @check_null obj_ptr
    return T(obj_ptr[1])
end

function lookup{T<:GitObject}(::Type{T}, r::Repository, id::String)
    id_arr  = Array(Uint8, api.OID_RAWSZ)
    @check api.git_oid_fromstrn(id_arr, bytestring(id), length(id))
    obj_ptr = Array(Ptr{Void}, 1)
    if length(id) < api.OID_HEXSZ
        @check api.git_object_lookup_prefix(obj_ptr, r.ptr, 
                                           id_arr, length(id),
                                           git_otype(T))
    else
        @check api.git_object_lookup(obj_ptr, r.ptr, 
                                     id_arr, length(id),
                                     git_otype(T))
    end
    @check_null obj_ptr
    return T(obj_ptr[1]) 
end

function lookup(r::Repository, id::Oid)
    @assert r.ptr != C_NULL
    obj_ptr = Array(Ptr{Void}, 1)
    @check api.git_object_lookup(obj_ptr, r.ptr, id.oid, api.OBJ_ANY)
    @check_null obj_ptr
    return gitobj_from_ptr(obj_ptr[1]) 
end

lookup_tree(r::Repository, id::Oid) = lookup(GitTree, r, id)
lookup_tree(r::Repository, id::String) = lookup(GitTree, r, id)
lookup_blob(r::Repository, id::Oid) = lookup(GitBlob, r, id)
lookup_blob(r::Repository, id::String) = lookup(GitBlob, r, id)
lookup_commit(r::Repository, id::Oid) = lookup(GitCommit, r, id)
lookup_commit(r::Repository, id::String) = lookup(GitCommit, r, id)

function lookup_ref(r::Repository, refname::String)
    @assert r.ptr != C_NULL
    bname = bytestring(refname)
    ref_ptr = Array(Ptr{Void}, 1)
    err = api.git_reference_lookup(ref_ptr, r.ptr, bname)
    if err == api.ENOTFOUND
        return nothing
    elseif err != api.GIT_OK
        return GitError(err)
    end
    @check_null ref_ptr
    return GitReference(ref_ptr[1])
end

function create_ref(r::Repository, refname::String,
                    id::Oid, force::Bool=false)
    @assert r.ptr != C_NULL
    bname = bytestring(refname)
    ref_ptr = Array(Ptr{Void}, 1)
    @check api.git_reference_create(ref_ptr, r.ptr, bname,
                                    id.oid, force? 1 : 0)
    @check_null ref_ptr
    return GitReference(ref_ptr[1])
end

function create_ref(r::Repository, refname::String, 
                    target::String, force::Bool=false)
    create_sym_ref(r, refname, target, force)
end

function create_sym_ref(r::Repository, refname::String,
                        target::String, force::Bool=false)
    @assert r.ptr != C_NULL
    bname = bytestring(refname)
    btarget = bytestring(target)
    ref_ptr = Array(Ptr{Void}, 1)
    @check api.git_reference_symbolic_create(ref_ptr, r.ptr, bname,
                                             btarget, force? 1 : 0)
    @check_null ref_ptr
    return GitReference(ref_ptr[1])
end


function repo_revparse_single(r::Repository, spec::String)
    @assert r.ptr != C_NULL
    bspec = bytestring(spec)
    obj_ptr = Array(Ptr{Void}, 1)
    @check api.git_revparse_single(obj_ptr, r.ptr, bspec)
    @check_null obj_ptr
    return gitobj_from_ptr(obj_ptr[1])
end

function commit(r::Repository,
                refname::String,
                author::Signature,
                committer::Signature,
                msg::String,
                tree::GitTree,
                parents::GitCommit...)
    @assert r.ptr != C_NULL
    @assert tree.ptr != C_NULL
    commit_oid  = Oid()
    bref = bytestring(refname)
    bmsg = bytestring(msg)
    nparents = convert(Cint, length(parents))
    cparents = Array(Ptr{Void}, nparents)
    if nparents > zero(Cint)
        for (i, commit) in enumerate(parents)
            @assert commit.ptr != C_NULL
            cparents[i] = commit.ptr

        end
    end
    gauthor = git_signature(author)
    gcommitter = git_signature(committer)
    #TODO: encoding?
    err_code = ccall((:git_commit_create, api.libgit2), Cint,
                     (Ptr{Uint8}, Ptr{Void}, Ptr{Cchar}, 
                      Ptr{api.GitSignature}, Ptr{api.GitSignature}, 
                      Ptr{Cchar}, Ptr{Cchar}, Ptr{Void},
                      Cint, Ptr{Ptr{Void}}),
                      commit_oid.oid, r.ptr, bref,
                      &gauthor, &gcommitter,
                      C_NULL, bmsg, tree.ptr, 
                      nparents, nparents > 0 ? cparents : C_NULL)
    if err_code < 0
        throw(GitError(err_code))
    end
    return commit_oid
end

function repo_set_workdir(r::Repository, dir::String, update::Bool)
end

# filter can be :all, :local, :remote
function branch_names(r::Repository, filter=:all)
    @assert r.ptr != C_NULL
    local git_filter::Cint 
    if filter == :all
        git_filter = api.BRANCH_LOCAL | api.BRANCH_REMOTE
    elseif filter == :local
        git_filter = api.BRANCH_LOCAL
    elseif filter == :remote
        git_filter = api.BRANCH_REMOTE
    else
        throw(ArgumentError("filter can be :all, :local, or :remote"))
    end
    iter_ptr = Array(Ptr{Void}, 1)
    @check api.git_branch_iterator_new(iter_ptr, r.ptr, git_filter)
    @check_null iter_ptr
    branch_ptr = Array(Ptr{Void}, 1)
    branch_type = Array(Cint, 1)
    names = String[]
    while true
        err = api.git_branch_next(branch_ptr, branch_type, iter_ptr[1])
        if err == api.ITEROVER
            break
        end
        if err != api.GIT_OK
            if iter_ptr[1] != C_NULL
                api.git_branch_iterator_free(iter_ptr[1])
            end
            throw(GitError(err))
        end
        name_ptr = api.git_reference_shorthand(branch_ptr[1])
        push!(names, bytestring(name_ptr)) 
    end
    api.git_branch_iterator_free(iter_ptr[1])
    return names
end

function lookup(::Type{GitBranch}, r::Repository,
                branch_name::String, branch_type=:local)
    @assert r.ptr != C_NULL
    local git_branch_type::Cint
    if branch_type == :local
        git_branch_type = api.BRANCH_LOCAL
    elseif branch_type == :remote 
        git_branch_type = api.BRANCH_REMOTE
    else
        throw(ArgumentError("branch_type can be :local or :remote"))
    end
    branch_ptr = Array(Ptr{Void}, 1)
    err = api.git_branch_lookup(branch_ptr, r.ptr,
                                 bytestring(branch_name), git_branch_type)
    if err == api.GIT_OK
        return GitBranch(branch_ptr[1])
    elseif err == api.ENOTFOUND
        return nothing
    else
        throw(GitError(err))
    end
end

lookup_branch(r::Repository, branch_name::String, branch_type=:local) = 
        lookup(GitBranch, r, branch_name, branch_type)

function create_branch(r::Repository, n::String, target::Oid, force::Bool=false)
    @assert r.ptr != C_NULL
    #TODO: give intelligent error msg when target
    # does not exist
    c = lookup_commit(r, target)
    branch_ptr = Array(Ptr{Void}, 1)
    @check api.git_branch_create(branch_ptr, r.ptr, bytestring(n),
                                 c.ptr, force? 1 : 0)
    return GitBranch(branch_ptr[1]) 
end

function create_branch(r::Repository, n::String,
                       target::String="HEAD", force::Bool=false)
    id = rev_parse_oid(r, target)
    return create_branch(r, n, id, force)
end

function create_branch(r::Repository, n::String,
                       target::GitCommit, force::Bool=false)
    id = oid(target)
    return create_branch(r, n, id, force)
end

type BranchIterator 
    ptr::Ptr{Void}
    repo::Repository

    function BranchIterator(ptr::Ptr{Void}, r::Repository)
        @assert ptr != C_NULL
        bi = new(ptr, r)
        finalizer(bi, free!)
        return bi
    end
end

free!(b::BranchIterator) = begin
    if b.ptr != C_NULL
        api.git_branch_iterator_free(b.ptr)
        b.ptr = C_NULL
    end
end

function iter_branches(r::Repository, filter=:all)
    @assert r.ptr != C_NULL
    local git_filter::Cint
    if filter == :all
        git_filter = api.BRANCH_LOCAL | api.BRANCH_REMOTE
    elseif filter == :local
        git_filter = api.BRANCH_LOCAL
    elseif filter == :remote
        git_filter == api.BRANCH_REMOTE
    else
        throw(ArgumentError("filter can be :all, :local, or :remote"))
    end 
    iter_ptr = Array(Ptr{Void}, 1)
    @check api.git_branch_iterator_new(iter_ptr, r.ptr, git_filter)
    @check_null iter_ptr
    return BranchIterator(iter_ptr[1], r)
end

Base.start(b::BranchIterator) = begin
    @assert b != C_NULL
    branch_ptr = Array(Ptr{Void}, 1)
    btype_ptr  = Array(Cint, 1)
    ret = api.git_branch_next(branch_ptr, btype_ptr, b.ptr)
    if ret == api.ITEROVER
        return nothing
    elseif ret != api.GIT_OK
        throw(GitError(ret))
    end
    @check_null branch_ptr
    return GitBranch(branch_ptr[1])
end

Base.done(b::BranchIterator, state) = begin
    state == nothing
end

Base.next(b::BranchIterator, state) = begin
    @assert b.ptr != C_NULL
    branch_ptr = Array(Ptr{Void}, 1)
    btype_ptr  = Array(Cint, 1)
    ret = api.git_branch_next(branch_ptr, btype_ptr, b.ptr)
    if ret == api.ITEROVER
        return (state, nothing)
    elseif ret != api.GIT_OK
        throw(GitError(ret))
    end
    @check_null branch_ptr
    return (state, GitBranch(branch_ptr[1]))
end

#------- Tree merge ---------
function parse_merge_options(opts::Nothing)
    return api.GitMergeTreeOpts()
end

function parse_merge_options(opts::Dict)
    merge_opts = api.GitMergeTreeOpts()
    if haskey(opts, :rename_threshold)
        merge_opts.rename_threshold = convert(Cuint, opts[:rename_threshold])
    end
    if haskey(opts, :target_limit)
        merge_opts.target_limit = convert(Cuint, opts[:target_limit])
    end
    if haskey(opts, :automerge)
        a = opts[:automerge]
        if a == :normal
            merge_opts.flags = api.MERGE_AUTOMERGE_NORMAL
        elseif a == :none
            merge_opts.flags = api.MERGE_AUTOMERGE_NONE
        elseif a == :favor_ours
            merge_opts.flags = api.MERGE_AUTOMERGE_FAVOR_OURS
        elseif a == :favor_theirs
            merge_opts.flags = api.MERGE_AUTOMERGE_FAVOR_THEIRS
        else
            error("Unknown automerge option :$a")
        end
    end
    if get(opts, :renames, false)
        merge_opts.flags |= MERGE_TREE_FIND_RENAMES
    end
    return merge_opts
end

#TODO: tree's should reference owning repository
Base.merge!(r::Repository, t1::GitTree, t2::GitTree, opts=nothing) = begin
    @assert r.ptr != C_NULL t1.ptr != C_NULL && t2.ptr != C_NULL 
    gopts = parse_merge_options(opts)
    idx_ptr = Array(Ptr{Void}, 1)
    @check ccall((:git_merge_trees, api.libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{api.GitMergeTreeOpts}),
                 idx_ptr, r.ptr, C_NULL, t1.ptr, t2.ptr, &gopts)
    @check_null idx_ptr
    return GitIndex(idx_ptr[1])
end

Base.merge!(r::Repository, t1::GitTree, t2::GitTree, ancestor::GitTree, opts=nothing) = begin
    @assert r.ptr != C_NULL t1.ptr != C_NULL && t2.ptr != C_NULL && ancestor.ptr != C_NULL
    gopts = parse_merge_options(opts)
    idx_ptr = Array(Ptr{Void}, 1)
    @check ccall((:git_merge_trees, api.libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{api.GitMergeTreeOpts}),
                 idx_ptr, r.ptr, ancestor.ptr, t1.ptr, t2.ptr, &gopts)
    @check_null idx_ptr
    return GitIndex(idx_ptr[1])
end

#------- Tree Builder -------
type TreeBuilder
    ptr::Ptr{Void}
    repo::Repository
    
    function TreeBuilder(ptr::Ptr{Void}, r::Repository)
        @assert ptr != C_NULL
        bld = new(ptr, r)
        finalizer(bld, free!)
        return bld
    end
end

free!(t::TreeBuilder) = begin
    if t.ptr != C_NULL
        api.git_treebuilder_free(t.ptr)
        t.ptr = C_NULL
    end
end

function insert!(t::TreeBuilder, filename::String,
                 id::Oid, filemode::Int)
    @assert t.ptr != C_NULL
    bfilename = bytstring(filename)
    cfilemode = convert(Cint, filemode)
    @check api.git_treebuilder_insert(C_NULL,
                                      t.ptr,
                                      bfilename, 
                                      id, 
                                      cfilemode)
    return t
end

function write!(t::TreeBuilder)
    @assert t.ptr != C_NULL
    oid_ptr = Array(Ptr{Void}, 1)
    @check api.git_treebuilder_write(oid, t.repo.ptr, t.ptr)
    @check_null oid_ptr
    return Oid(oid_ptr[1])
end

function repo_treebuilder(r::Repository)
    @assert r.ptr != C_NULL
    bld_ptr = Array(Ptr{Void}, 1)
    @check api.git_treebuilder_create(bld_ptr, C_NULL)
    @check_null bld_ptr
    return TreeBuilder(bld_ptr[1], r)
end

#-------- Reference Iterator --------
#TODO: handle error's when iterating (see branch)
type ReferenceIterator
    ptr::Ptr{Void}
    repo::Repository

    function ReferenceIterator(ptr::Ptr{Void}, r::Repository)
        @assert ptr != C_NULL
        ri = new(ptr, r)
        finalizer(ri, free!)
        return ri
    end
end

free!(r::ReferenceIterator) = begin
    if r.ptr != C_NULL
        api.git_reference_iterator_free(r.ptr)
        r.ptr = C_NULL
    end
end

function ref_names(r::Repository, glob=nothing)
    rnames = String[]
    for r in iter_refs(r, glob)
        push!(rnames, name(r))
    end
    return rnames
end

function iter_refs(r::Repository, glob=nothing)
    @assert r.ptr != C_NULL
    iter_ptr = Array(Ptr{Void}, 1)
    if glob == nothing
        @check api.git_reference_iterator_new(iter_ptr, r.ptr)
    else
        bglob = bytestring(glob)
        @check api.git_reference_iterator_glob_new(iter_ptr, r.ptr, bglob)
    end
    @check_null iter_ptr
    return ReferenceIterator(iter_ptr[1], r)
end

Base.start(r::ReferenceIterator) = begin
    @assert r != C_NULL
    ref_ptr = Array(Ptr{Void}, 1)
    ret = api.git_reference_next(ref_ptr, r.ptr)
    if ret == api.ITEROVER
        return nothing
    end
    @check_null ref_ptr
    return GitReference(ref_ptr[1])
end

Base.done(r::ReferenceIterator, state) = begin
    state == nothing
end

Base.next(r::ReferenceIterator, state) = begin
    @assert r.ptr != C_NULL
    ref_ptr = Array(Ptr{Void}, 1)
    ret = api.git_reference_next(ref_ptr, r.ptr)
    if ret == api.ITEROVER
        return (state, nothing)
    end
    @check_null ref_ptr
    return (state, GitReference(ref_ptr[1]))
end
