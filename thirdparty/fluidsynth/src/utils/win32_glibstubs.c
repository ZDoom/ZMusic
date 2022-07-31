#ifdef WIN32

#define _CRT_SECURE_NO_WARNINGS

#include "fluidsynth_priv.h"
#include "fluid_sys.h"
#include "win32_glibstubs.h"

#include <process.h>

static wchar_t *utf8_to_wc(const char *str)
{
    if (str == NULL)
    {
        return NULL;
    }
    wchar_t *wstr = NULL;
    int length;

    if ((length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, str, -1, NULL, 0)) == 0)
    {
        return NULL;
    }
    wstr = malloc(length * sizeof(wchar_t));
    if (wstr == NULL)
    {
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, str, -1, wstr, length);
    return wstr;
}

BOOL fluid_g_file_test(const char *pathA, int flags)
{
    wchar_t *path = utf8_to_wc(pathA);
    if (path == NULL)
    {
        return FALSE;
    }
    DWORD attributes = GetFileAttributesW(path);
    FLUID_FREE(path);
    if (attributes == INVALID_FILE_ATTRIBUTES)
    {
        return FALSE;
    }
    if (flags & G_FILE_TEST_EXISTS)
    {
        return TRUE;
    }
    if (flags & G_FILE_TEST_IS_REGULAR)
    {
        return (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)) == 0;
    }
    return FALSE;
}

// ParseCommandLine - Taken from ZDoom
//
// Parse a command line (passed in args). If argc is non-NULL, it will
// be set to the number of arguments. If argv is non-NULL, it will be
// filled with pointers to each argument; argv[0] should be initialized
// to point to a buffer large enough to hold all the arguments. The
// return value is the necessary size of this buffer.
//
// Special processing:
//   Inside quoted strings, \" becomes just "
//                          \\ becomes just a single backslash

static long ParseCommandLine(const char *args, int *argc, char **argv)
{
    int count;
    char *buffer;
    long buffplace;

    count = 0;
    buffplace = 0;
    buffer = argv != NULL ? argv[0] : NULL;

    for (;;)
    {
        while (*args <= ' ' && *args)
        { // skip white space
            args++;
        }
        if (*args == 0)
        {
            break;
        }
        else if (*args == '\"')
        { // read quoted string
            char stuff;
            if (argv != NULL)
            {
                argv[count] = buffer + buffplace;
            }
            count++;
            args++;
            do
            {
                stuff = *args++;
                if (stuff == '\\' && *args == '\"')
                {
                    stuff = '\"';
                    args++;
                }
                else if (stuff == '\\' && *args == '\\')
                {
                    args++;
                }
                else if (stuff == '\"')
                {
                    stuff = 0;
                }
                else if (stuff == 0)
                {
                    args--;
                }
                if (argv != NULL)
                {
                    buffer[buffplace] = stuff;
                }
                buffplace++;
            } while (stuff);
        }
        else
        { // read unquoted string
            const char *start = args++, *end;

            while (*args && *args > ' ' && *args != '\"')
            {
                args++;
            }
            end = args;
            if (argv != NULL)
            {
                argv[count] = buffer + buffplace;
                while (start < end)
                {
                    buffer[buffplace++] = *start++;
                }
                buffer[buffplace++] = 0;
            }
            else
            {
                buffplace += end - start + 1;
            }
            count++;
        }
    }
    if (argc != NULL)
    {
        *argc = count;
    }
    return buffplace;
}

BOOL fluid_g_shell_parse_argv(const char *command_line, int *argcp, char ***argvp, void *_)
{
    long argsize = ParseCommandLine(command_line, argcp, NULL);
    *argvp = NULL;
    if (*argcp != 0)
    {
        *argvp = (char **)malloc(*argcp * sizeof(char *) + argsize);
        if (!*argvp)
        {
            return FALSE;
        }
        **argvp = (char *)*argvp + *argcp * sizeof(char *);
        ParseCommandLine(command_line, NULL, *argvp);
    }
    return TRUE;
}

double fluid_g_get_monotonic_time(void)
{
    static LARGE_INTEGER freq_cache = { 0, 0 }; /* Performance Frequency */
    LARGE_INTEGER perf_cpt;

    if (!freq_cache.QuadPart)
    {
        QueryPerformanceFrequency(&freq_cache); /* Frequency value */
    }

    QueryPerformanceCounter(&perf_cpt);                         /* Counter value */
    return perf_cpt.QuadPart * 1000000.0 / freq_cache.QuadPart; /* time in micros */
}

/* Thread support */
static unsigned __stdcall g_thread_wrapper(void *info_)
{
    GThread *info = (GThread *)info_;
    info->func(info->data);
    /* Free the "GThread" now if it was detached. Otherwise, it's freed in fluid_g_thread_join. */
    if (info->handle == NULL)
    {
        free(info);
    }
    _endthreadex(0);
    return 0;
}

GThread *fluid_g_thread_create(GThreadFunc func, void *data, BOOL joinable, GError **error)
{
    static GError error_container;

    g_return_val_if_fail(func != NULL, NULL);

    GThread *info = (GThread *)malloc(sizeof(GThread));
    if (info == NULL)
    {
        return NULL;
    }

    info->func = func;
    info->data = data;

    HANDLE thread = (HANDLE)_beginthreadex(NULL, 0, g_thread_wrapper, info, CREATE_SUSPENDED, NULL);

    if (error != NULL)
    {
        error_container.code = thread ? 0 : errno;
        if (errno != 0)
        {
            error_container.message = strerror(errno);
        }
        *error = &error_container;
    }

    if (thread == NULL)
    {
        free(info);
        info = NULL;
    }
    else
    {
        if (!joinable)
        {
            /* Release thread reference, if caller doesn't want to join */
            CloseHandle(thread);
            info->handle = NULL;
        }
        else
        {
            info->handle = thread;
        }
        ResumeThread(thread);
    }
    return info;
}

void fluid_g_thread_join(GThread *thread)
{
    if (thread != NULL && thread->handle != NULL)
    {
        WaitForSingleObject(thread->handle, INFINITE);
        CloseHandle(thread->handle);
        free(thread);
    }
}

#endif