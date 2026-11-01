# Test runner self-test

`run-selftest` tests `tests/run` and the helpers in `tests/framework.sh` and `tests/framework.py`:

```sh
tests/selftest/run-selftest            # fake tests only; no Docker needed (about 15s)
tests/selftest/run-selftest --docker   # also real Docker in stand-in mode (about 40s)
tests/selftest/run-selftest -v         # verbose; other unittest arguments also accepted
```

With `--docker`, it runs the repository's tests with `tests/run --mock` (standard `runc` in place of RunCVM; tests requiring `vm` are skipped), and real-Docker scenarios: a failing check, a test that leaves containers, networks and volumes behind (which the runner must remove), a test hung on `docker logs -f` (which must time out and be cleaned up), the volume helpers in both languages, and two runs at once.

## Developing in a sandbox without KVM

Stand-in mode needs only a Docker daemon and the `alpine` and `mariadb` images. In a sandboxed environment where `dockerd` is not running, it can usually be started directly:

```sh
dockerd --iptables=false --ip6tables=false >/tmp/dockerd.log 2>&1 &
docker pull alpine && docker pull mariadb
```

If outbound access is only through a proxy, pulling images works when `dockerd` inherits the proxy settings, but containers on Docker networks may have no outbound access at all. The repository's tests avoid downloading anything at run time for this reason.
