import assert from 'node:assert/strict'
import test from 'node:test'
import { debounce } from '../src/domain/debounce.ts'

test('debounce: wait 窗口内连续调用只执行最后一次（取最新参数）', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const calls: string[] = []
  const debounced = debounce((value: string) => calls.push(value), 300)
  debounced('p')
  debounced('py')
  debounced('python')
  t.mock.timers.tick(299)
  assert.deepEqual(calls, [])
  t.mock.timers.tick(1)
  assert.deepEqual(calls, ['python'])
})

test('debounce: 间隔超过 wait 的调用各自执行', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const calls: string[] = []
  const debounced = debounce((value: string) => calls.push(value), 300)
  debounced('a')
  t.mock.timers.tick(300)
  debounced('b')
  t.mock.timers.tick(300)
  assert.deepEqual(calls, ['a', 'b'])
})

test('debounce: cancel 丢弃挂起调用', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const calls: string[] = []
  const debounced = debounce((value: string) => calls.push(value), 300)
  debounced('x')
  debounced.cancel()
  t.mock.timers.tick(1000)
  assert.deepEqual(calls, [])
})
