from __future__ import print_function
import os
import sys
import cython

from libc.stdlib cimport free
from libc.string cimport strerror
from libc.errno cimport *
cimport defs

cdef extern from "pwd.h":
    ctypedef int time_t
    ctypedef int uid_t
    ctypedef int gid_t
    
    cdef struct passwd:
        char	*pw_name
        char	*pw_passwd
        uid_t	pw_uid
        gid_t	pw_gid
        time_t	pw_change
        char	*pw_class
        char	*pw_gecos
        char	*pw_dir
        char	*pw_shell
        time_t	pw_expire
        int	pw_fields
        
cdef extern from "yp_client.h":
    cdef extern void *yp_client_init(const char *domain, const char *server)
    cdef extern void yp_client_close(void *context)
    cdef extern int yp_client_match(void *context,
                                    const char *inmap, const char *inkey, size_t inkeylen,
                                    char **outval, size_t *outvallen)
    cdef extern int yp_client_first(void *context, const char *inmap,
                                    const char **outkey, size_t *outkeylen,
                                    const char **outval, size_t *outvallen)
    cdef extern int yp_client_next(void *context, const char *inmap,
                                   const char *inkey, size_t inkeylen,
                                   const char **outkey, size_t *outkeylen,
                                   const char **outval, size_t *outvallen)
    cdef extern int yp_client_update_pwent(void *context,
                                           const char *old_password,
                                           const passwd *pwent)
class grp(object):
    def __init__(self, gr_name=None, gr_passwd='*', gr_gid=None, gr_mem=[]):
        self.gr_name = gr_name
        self.gr_passwd = gr_passwd
        self.gr_gid = gr_gid
        if isinstance(gr_mem, list):
            self.gr_mem = gr_mem
        else:
            self.gr_mem = [gr_mem]
    def __repr__(self):
        return "{}(gr_name='{}', gr_passwd='{}', gr_gid={}, gr_mem={})".format(
            self.__class__.__name__,
            self.gr_name, self.gr_passwd, self.gr_gid, self.gr_mem)
    def __str__(self):
        return "{}:{}:{}:{}".format(self.gr_name, self.gr_passwd, self.gr_gid,
                                    ",".join(self.gr_mem))
            
def _make_pwent(pw):
    return "{}:{}:{}:{}:{}:{}:{}".format(
        pw.pw_name, pw.pw_passwd, pw.pw_uid,
        pw.pw_gid, pw.pw_gecos, pw.pw_dir,
        pw.pw_shell)

def _make_gr(entry):
    fields = entry.split(':')
    return grp(gr_name=fields[0],
               gr_passwd=fields[1],
               gr_gid=fields[2],
               gr_mem=fields[3].split(','))

cdef _make_pw(entry):
    cdef passwd retval
    fields = entry.split(':')
    retval.pw_name = fields[0]
    retval.pw_passwd = fields[1]
    retval.pw_uid = int(fields[2])
    retval.pw_gid = int(fields[3])
    retval.pw_gecos = fields[4]
    retval.pw_dir = fields[5]
    retval.pw_shell = fields[6]
    # Now all the ones not defined by that
    retval.pw_change = 0
    retval.pw_class = ""
    retval.pw_expire = 0
    retval.pw_fields = 1
    return retval

cdef class NIS(object):
    cdef void *ctx
    cdef const char *domain
    cdef const char *server
    def __init__(self, domain=None, server=None):
        self.ctx = yp_client_init(domain, server)
        if self.ctx == NULL:
            raise OSError(ENOMEM, strerror(ENOMEM))
        self.domain = domain
        self.server = server
        return

    def _getpw(self, mapname, keyvalue):
        cdef char *pw_ent = NULL
        cdef size_t pw_ent_len
        
        rv = yp_client_match(self.ctx, mapname, keyvalue, len(keyvalue), &pw_ent, &pw_ent_len)
        if rv != 0:
            raise OSError(rv, strerror(rv))
        
        retval = _make_pwent(pw_ent.decode('utf-8'))
        free(pw_ent)
        if retval:
            return retval
        raise OSError(ENOENT, "Cannot find key {} in map {}".format(keyvalue, mapname))
        
    def _get_entries(self, mapname, cracker):
        """
        Generic function to get multiple entries (e.g., getpwent and getgrent).
        This is slightly different from the libc routines, in that
        we simply call yp_client_first() for the proper map, and then
        yield results until yp_client_next() returns an error.
        """
        cdef const char *first_key = NULL
        cdef const char *next_key = NULL
        cdef const char *out_value = NULL
        cdef size_t first_keylen, next_keylen, out_len

        try:
            rv = yp_client_first(self.ctx, mapname,
                                 &next_key, &next_keylen,
                                 &out_value, &out_len)
            while rv == 0:
                retval = cracker(out_value.decode('utf-8'))
                free(<void*>out_value)
                free(<void*>first_key)
                first_key = next_key
                first_keylen = next_keylen
                next_key = NULL
                next_keylen = 0
                yield retval
                rv = yp_client_next(self.ctx, mapname,
                                    first_key, first_keylen,
                                    &next_key, &next_keylen,
                                    &out_value, &out_len)
        finally:
            if first_key:
                free(<void*>first_key)
            if next_key:
                free(<void*>next_key)

    def getpwent(self):
        if os.geteuid() == 0:
            mapname = "master.passwd.byname"
        else:
            mapname = "passwd.byname"

        return self._get_entries(mapname, _make_pw)
            
    def getpwnam(self, name):
        if os.geteuid() == 0:
            mapname = "master.passwd.byname"
        else:
            mapname = "passwd.byname"
            
        return self._getpw(mapname, name)

    def getpwuid(self, uid):
        if os.geteuid() == 0:
            mapname = "master.passwd.byuid"
        else:
            mapname = "passwd.byuid"
            
        return self._getpw(mapname, str(uid))

    def _getgr(self, mapname, keyvalue):
        cdef char *gr_ent = NULL
        cdef size_t gr_ent_len
        
        rv = yp_client_match(self.ctx, mapname, keyvalue, len(keyvalue), &gr_ent, &gr_ent_len)
        if rv != 0:
            raise OSError(rv, strerror(rv))
        
        retval = _make_gr(gr_ent.decode('utf-8'))
        free(gr_ent)
        if retval:
            return retval
        raise OSError(ENOENT, "Cannot find key {} in map {}".format(keyvalue, mapname))

    def getgrnam(self, grpname):
        if grpname is None:
            raise ValueError("grpname must be defined")
        return self._getgr("group.byname", grpname)

    def getgrgid(self, guid):
        return self._getgr("group.bygid", str(guid))
    
    def getgrent(self):
        return self._get_entries("group.byname", _make_gr)

    def update_pwent(self, old_password, new_pwent):
        cdef passwd pwent_copy
        pwent_copy.pw_name = new_pwent.pw_name
        pwent_copy.pw_passwd = new_pwent.pw_passwd
        pwent_copy.pw_uid = new_pwent.pw_uid
        pwent_copy.pw_gid = new_pwent.pw_gid
        pwent_copy.pw_gecos = new_pwent.pw_gecos
        pwent_copy.pw_dir = new_pwent.pw_dir
        pwent_copy.pw_shell = new_pwent.pw_shell
        pwent_copy.pw_fields = 1

        try:
            pwent_copy.pw_change = new_pwent.pw_change
        except:
            pwent_copy.pw_change = 0
        try:
            pwent_copy.pw_class = new_pwent.pw_class
            if pwent_copy.pw_class == NULL:
                pwent_copy.pw_class = ""
        except:
            pwent_copy.pw_class = ""
        try:
            pwent_copy.pw_expire = new_pwent.pw_expire
        except:
            pwent_copy.pw_exire = 0

        rv = yp_client_update_pwent(self.ctx, old_password, &pwent_copy)
        return
