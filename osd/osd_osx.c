//============================================================
//
//  sdlos_*.c - OS specific low level code
//
//  Copyright (c) 1996-2010, Nicola Salmoria and the MAME Team.
//  Visit http://mamedev.org for licensing and usage restrictions.
//
//  SDLMAME by Olivier Galibert and R. Belmont
//
//============================================================

#include <sys/stat.h>
#include <sys/time.h>

#include <mach/mach.h>
#include <mach/mach_time.h>

#include <pthread.h>

#include "osdcore.h"
#include "sdlsync.h"

struct hidden_mutex_t {
	pthread_mutex_t id;
};

struct osd_event {
	pthread_mutex_t     mutex;
	pthread_cond_t      cond;
	volatile INT32      autoreset;
	volatile INT32      signalled;
#ifdef PTR64
	INT8                padding[40];    // Fill a 64-byte cache line
#else
	INT8                padding[48];    // A bit more padding
#endif
};

//============================================================
//  TYPE DEFINITIONS
//============================================================

struct osd_thread {
	pthread_t           thread;
};

struct osd_scalable_lock
{
	osd_lock            *lock;
};

//============================================================
//   osd_ticks
//============================================================

osd_ticks_t osd_ticks(void)
{
	return mach_absolute_time();
}

//============================================================
//  osd_ticks_per_second
//============================================================

osd_ticks_t osd_ticks_per_second(void)
{
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    
    return 1000000000LL * ((uint64_t)info.denom) / ((uint64_t)info.numer);
}

//============================================================
//  osd_sleep
//============================================================

void osd_sleep(osd_ticks_t duration)
{
	UINT32 msec;
    
	// convert to milliseconds, rounding down
	msec = (UINT32)(duration * 1000 / osd_ticks_per_second());
    
	// only sleep if at least 2 full milliseconds
	if (msec >= 2)
	{
		// take a couple of msecs off the top for good measure
		msec -= 2;
		usleep(msec*1000);
	}
}

//============================================================
//  Scalable Locks
//============================================================

osd_scalable_lock *osd_scalable_lock_alloc(void)
{
	osd_scalable_lock *lock;
    
	lock = (osd_scalable_lock *)calloc(1, sizeof(*lock));
    
	lock->lock = osd_lock_alloc();
	return lock;
}


INT32 osd_scalable_lock_acquire(osd_scalable_lock *lock)
{
	osd_lock_acquire(lock->lock);
	return 0;
}


void osd_scalable_lock_release(osd_scalable_lock *lock, INT32 myslot)
{
	osd_lock_release(lock->lock);
}

void osd_scalable_lock_free(osd_scalable_lock *lock)
{
	osd_lock_free(lock->lock);
	free(lock);
}


//============================================================
//  osd_lock_alloc
//============================================================

osd_lock *osd_lock_alloc(void)
{
	hidden_mutex_t *mutex;
	pthread_mutexattr_t mtxattr;
    
	mutex = (hidden_mutex_t *)calloc(1, sizeof(hidden_mutex_t));
    
	pthread_mutexattr_init(&mtxattr);
	pthread_mutexattr_settype(&mtxattr, PTHREAD_MUTEX_RECURSIVE);
	pthread_mutex_init(&mutex->id, &mtxattr);
    
	return (osd_lock *)mutex;
}

//============================================================
//  osd_lock_acquire
//============================================================

void osd_lock_acquire(osd_lock *lock)
{
	hidden_mutex_t *mutex = (hidden_mutex_t *) lock;
	int r;
    
	r = pthread_mutex_lock(&mutex->id);
	if (r==0)
		return;
	//mame_printf_error("Error on lock: %d: %s\n", r, strerror(r));
}

//============================================================
//  osd_lock_try
//============================================================

int osd_lock_try(osd_lock *lock)
{
	hidden_mutex_t *mutex = (hidden_mutex_t *) lock;
	int r;
    
	r = pthread_mutex_trylock(&mutex->id);
	if (r==0)
		return 1;
	//if (r!=EBUSY)
	//  mame_printf_error("Error on trylock: %d: %s\n", r, strerror(r));
	return 0;
}

//============================================================
//  osd_lock_release
//============================================================

void osd_lock_release(osd_lock *lock)
{
	hidden_mutex_t *mutex = (hidden_mutex_t *) lock;
    
	pthread_mutex_unlock(&mutex->id);
}

//============================================================
//  osd_lock_free
//============================================================

void osd_lock_free(osd_lock *lock)
{
	hidden_mutex_t *mutex = (hidden_mutex_t *) lock;
    
	pthread_mutex_unlock(&mutex->id);
	pthread_mutex_destroy(&mutex->id);
	free(mutex);
}

//============================================================
//  osd_event_alloc
//============================================================

osd_event *osd_event_alloc(int manualreset, int initialstate)
{
	osd_event *ev;
	pthread_mutexattr_t mtxattr;
    
	ev = (osd_event *)calloc(1, sizeof(osd_event));
    
	pthread_mutexattr_init(&mtxattr);
	pthread_mutex_init(&ev->mutex, &mtxattr);
	pthread_cond_init(&ev->cond, NULL);
	ev->signalled = initialstate;
	ev->autoreset = !manualreset;
    
	return ev;
}

//============================================================
//  osd_event_free
//============================================================

void osd_event_free(osd_event *event)
{
	pthread_mutex_destroy(&event->mutex);
	pthread_cond_destroy(&event->cond);
	free(event);
}

//============================================================
//  osd_event_set
//============================================================

void osd_event_set(osd_event *event)
{
	pthread_mutex_lock(&event->mutex);
	if (event->signalled == FALSE)
	{
		event->signalled = TRUE;
		if (event->autoreset)
			pthread_cond_signal(&event->cond);
		else
			pthread_cond_broadcast(&event->cond);
	}
	pthread_mutex_unlock(&event->mutex);
}

//============================================================
//  osd_event_reset
//============================================================

void osd_event_reset(osd_event *event)
{
	pthread_mutex_lock(&event->mutex);
	event->signalled = FALSE;
	pthread_mutex_unlock(&event->mutex);
}

//============================================================
//  osd_event_wait
//============================================================

int osd_event_wait(osd_event *event, osd_ticks_t timeout)
{
	pthread_mutex_lock(&event->mutex);
	if (!timeout)
	{
		if (!event->signalled)
		{
            pthread_mutex_unlock(&event->mutex);
            return FALSE;
		}
	}
	else
	{
		if (!event->signalled)
		{
			struct timespec   ts;
			struct timeval    tp;
			UINT64 msec = timeout * 1000 / osd_ticks_per_second();
			UINT64 nsec;
            
			gettimeofday(&tp, NULL);
            
			ts.tv_sec  = tp.tv_sec;
			nsec = (UINT64) tp.tv_usec * (UINT64) 1000 + (msec * (UINT64) 1000000);
			ts.tv_nsec = nsec % (UINT64) 1000000000;
			ts.tv_sec += nsec / (UINT64) 1000000000;
            
			do {
				int ret = pthread_cond_timedwait(&event->cond, &event->mutex, &ts);
				if ( ret == ETIMEDOUT )
				{
					if (!event->signalled)
					{
						pthread_mutex_unlock(&event->mutex);
						return FALSE;
					}
					else
						break;
				}
				if (ret == 0)
					break;
				if ( ret != EINTR)
				{
					printf("Error %d while waiting for pthread_cond_timedwait:  %s\n", ret, strerror(ret));
				}
                
			} while (TRUE);
		}
	}
    
	if (event->autoreset)
		event->signalled = 0;
    
	pthread_mutex_unlock(&event->mutex);
    
	return TRUE;
}

//============================================================
//  osd_thread_create
//============================================================

osd_thread *osd_thread_create(osd_thread_callback callback, void *cbparam)
{
	osd_thread *thread;
	pthread_attr_t  attr;
    
	thread = (osd_thread *)calloc(1, sizeof(osd_thread));
	pthread_attr_init(&attr);
	pthread_attr_setinheritsched(&attr, PTHREAD_INHERIT_SCHED);
	if ( pthread_create(&thread->thread, &attr, callback, cbparam) != 0 )
	{
		free(thread);
		return NULL;
	}
	return thread;
}

//============================================================
//  osd_thread_adjust_priority
//============================================================

int osd_thread_adjust_priority(osd_thread *thread, int adjust)
{
	struct sched_param  sched;
	int                 policy;
    
	if ( pthread_getschedparam( thread->thread, &policy, &sched ) == 0 )
	{
		sched.sched_priority += adjust;
		if ( pthread_setschedparam(thread->thread, policy, &sched ) == 0)
			return TRUE;
		else
			return FALSE;
	}
	else
		return FALSE;
}

//============================================================
//  osd_thread_cpu_affinity
//============================================================

int osd_thread_cpu_affinity(osd_thread *thread, UINT32 mask)
{
    return FALSE;
}

//============================================================
//  osd_thread_wait_free
//============================================================

void osd_thread_wait_free(osd_thread *thread)
{
	pthread_join(thread->thread, NULL);
	free(thread);
}

//============================================================
//  osd_process_kill
//============================================================

void osd_process_kill(void)
{
	kill(getpid(), SIGKILL);
}

//============================================================
//  osd_num_processors
//============================================================

int osd_get_num_processors(void)
{
	int processors = 1;
    
	struct host_basic_info host_basic_info;
	unsigned int count;
	kern_return_t r;
	mach_port_t my_mach_host_self;
    
	count = HOST_BASIC_INFO_COUNT;
	my_mach_host_self = mach_host_self();
	if ( ( r = host_info(my_mach_host_self, HOST_BASIC_INFO, (host_info_t)(&host_basic_info), &count)) == KERN_SUCCESS )
	{
		processors = host_basic_info.avail_cpus;
	}
	mach_port_deallocate(mach_task_self(), my_mach_host_self);
    
	return processors;
}

//============================================================
//  osd_malloc
//============================================================

void *osd_malloc(size_t size)
{
#ifndef MALLOC_DEBUG
	return malloc(size);
#else
#error "MALLOC_DEBUG not yet supported"
#endif
}


//============================================================
//  osd_malloc_array
//============================================================

void *osd_malloc_array(size_t size)
{
#ifndef MALLOC_DEBUG
	return malloc(size);
#else
#error "MALLOC_DEBUG not yet supported"
#endif
}


//============================================================
//  osd_free
//============================================================

void osd_free(void *ptr)
{
#ifndef MALLOC_DEBUG
	free(ptr);
#else
#error "MALLOC_DEBUG not yet supported"
#endif
}

//============================================================
//  osd_getenv
//============================================================

char *osd_getenv(const char *name)
{
	return getenv(name);
}

//============================================================
//  osd_setenv
//============================================================

int osd_setenv(const char *name, const char *value, int overwrite)
{
	return setenv(name, value, overwrite);
}


//============================================================
//  osd_get_clipboard_text
//============================================================

char *osd_get_clipboard_text(void)
{
	char *result = NULL; /* core expects a malloced C string of uft8 data */
    
	PasteboardRef pasteboard_ref;
	OSStatus err;
	PasteboardSyncFlags sync_flags;
	PasteboardItemID item_id;
	CFIndex flavor_count;
	CFArrayRef flavor_type_array;
	CFIndex flavor_index;
	ItemCount item_count;
	UInt32 item_index;
	Boolean success = false;
    
	err = PasteboardCreate(kPasteboardClipboard, &pasteboard_ref);
    
	if (!err)
	{
		sync_flags = PasteboardSynchronize( pasteboard_ref );
        
		err = PasteboardGetItemCount(pasteboard_ref, &item_count );
        
		for (item_index=1; item_index<=item_count; item_index++)
		{
			err = PasteboardGetItemIdentifier(pasteboard_ref, item_index, &item_id);
            
			if (!err)
			{
				err = PasteboardCopyItemFlavors(pasteboard_ref, item_id, &flavor_type_array);
                
				if (!err)
				{
					flavor_count = CFArrayGetCount(flavor_type_array);
                    
					for (flavor_index = 0; flavor_index < flavor_count; flavor_index++)
					{
						CFStringRef flavor_type;
						CFDataRef flavor_data;
						CFStringEncoding encoding;
						CFStringRef string_ref;
						CFDataRef data_ref;
						CFIndex length;
						CFRange range;
                        
						flavor_type = (CFStringRef)CFArrayGetValueAtIndex(flavor_type_array, flavor_index);
                        
						if (UTTypeConformsTo (flavor_type, kUTTypeUTF16PlainText))
							encoding = kCFStringEncodingUTF16;
						else if (UTTypeConformsTo (flavor_type, kUTTypeUTF8PlainText))
							encoding = kCFStringEncodingUTF8;
						else if (UTTypeConformsTo (flavor_type, kUTTypePlainText))
							encoding = kCFStringEncodingMacRoman;
						else
							continue;
                        
						err = PasteboardCopyItemFlavorData(pasteboard_ref, item_id, flavor_type, &flavor_data);
                        
						if( !err )
						{
							string_ref = CFStringCreateFromExternalRepresentation (kCFAllocatorDefault, flavor_data, encoding);
							data_ref = CFStringCreateExternalRepresentation (kCFAllocatorDefault, string_ref, kCFStringEncodingUTF8, '?');
                            
							length = CFDataGetLength (data_ref);
							range = CFRangeMake (0,length);
                            
							result = (char *)osd_malloc_array (length+1);
							if (result != NULL)
							{
								CFDataGetBytes (data_ref, range, (unsigned char *)result);
								result[length] = 0;
								success = true;
								break;
							}
                            
							CFRelease(data_ref);
							CFRelease(string_ref);
							CFRelease(flavor_data);
						}
					}
                    
					CFRelease(flavor_type_array);
				}
			}
            
			if (success)
				break;
		}
        
		CFRelease(pasteboard_ref);
	}
    
	return result;
}

//============================================================
//  osd_stat
//============================================================

osd_directory_entry *osd_stat(const char *path)
{
	int err;
	osd_directory_entry *result = NULL;

	struct stat st;
    
	err = stat(path, &st);
    
	if( err == -1) return NULL;
    
	// create an osd_directory_entry; be sure to make sure that the caller can
	// free all resources by just freeing the resulting osd_directory_entry
	result = (osd_directory_entry *) osd_malloc_array(sizeof(*result) + strlen(path) + 1);
	strcpy(((char *) result) + sizeof(*result), path);
	result->name = ((char *) result) + sizeof(*result);
	result->type = S_ISDIR(st.st_mode) ? ENTTYPE_DIR : ENTTYPE_FILE;
	result->size = (UINT64)st.st_size;
    
	return result;
}

//============================================================
//  osd_get_volume_name
//============================================================

const char *osd_get_volume_name(int idx)
{
	if (idx!=0) return NULL;
	return "/";
}

//============================================================
//  osd_get_slider_list
//============================================================

const void *osd_get_slider_list()
{
	return NULL;
}

//============================================================
//  osd_get_full_path
//============================================================

file_error osd_get_full_path(char **dst, const char *path)
{
	file_error err;
	char path_buffer[512];
    
	err = FILERR_NONE;
    
	if (getcwd(path_buffer, 511) == NULL)
	{
		printf("osd_get_full_path: failed!\n");
		err = FILERR_FAILURE;
	}
	else
	{
		*dst = (char *)osd_malloc_array(strlen(path_buffer)+strlen(path)+3);
        
		// if it's already a full path, just pass it through
		if (path[0] == '/')
		{
			strcpy(*dst, path);
		}
		else
		{
			sprintf(*dst, "%s%s%s", path_buffer, PATH_SEPARATOR, path);
		}
	}
    
	return err;
}
