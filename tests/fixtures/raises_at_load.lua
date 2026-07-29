-- Fixture for the harness self-check ONLY. Not production code and not loaded
-- by anything the server runs. It exists so the self-check can prove that
-- T.loadFile surfaces a runtime error instead of swallowing it.
error('this fixture raises on purpose')
