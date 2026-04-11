/*
Copyright (C) 2025 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/

import React, { useEffect, useState, useRef } from 'react';
import { Button, Col, Form, Popconfirm, Row, Spin } from '@douyinfe/semi-ui';
import { useTranslation } from 'react-i18next';
import {
  compareObjects,
  API,
  showError,
  showSuccess,
  showWarning,
} from '../../../helpers';

export default function SettingsCreditLimit(props) {
  const { t } = useTranslation();
  const [loading, setLoading] = useState(false);
  const [settlementLoading, setSettlementLoading] = useState(false);
  const [inputs, setInputs] = useState({
    QuotaForNewUser: '',
    PreConsumedQuota: '',
    QuotaForInviter: '',
    QuotaForInvitee: '',
    AffCommissionPercentage: '',
    'quota_setting.enable_free_model_pre_consume': true,
  });
  const refForm = useRef();
  const [inputsRow, setInputsRow] = useState(inputs);

  function onSubmit() {
    const updateArray = compareObjects(inputs, inputsRow);
    if (!updateArray.length) return showWarning(t('你似乎并没有修改什么'));
    const requestQueue = updateArray.map((item) => {
      let value = '';
      if (typeof inputs[item.key] === 'boolean') {
        value = String(inputs[item.key]);
      } else {
        value = inputs[item.key];
      }
      return API.put('/api/option/', {
        key: item.key,
        value,
      });
    });
    setLoading(true);
    Promise.all(requestQueue)
      .then((res) => {
        if (requestQueue.length === 1) {
          if (res.includes(undefined)) return;
        } else if (requestQueue.length > 1) {
          if (res.includes(undefined))
            return showError(t('部分保存失败，请重试'));
        }
        showSuccess(t('保存成功'));
        props.refresh();
      })
      .catch(() => {
        showError(t('保存失败，请重试'));
      })
      .finally(() => {
        setLoading(false);
      });
  }

  async function triggerYesterdayAffSettlement() {
    setSettlementLoading(true);
    try {
      const res = await API.post(
        '/api/option/aff_daily_commission/settle_yesterday',
      );
      const { success, message, data } = res.data;
      if (!success) {
        showError(message || t('执行失败'));
        return;
      }
      showSuccess(
        t(
          '昨日返佣结算已执行：日期 {{date}}，结算 {{settled}} 人，返佣 {{rewarded}} 人，返佣额度 {{quota}}',
          {
            date: data?.settle_date || '-',
            settled: data?.settled_count || 0,
            rewarded: data?.rewarded_count || 0,
            quota: data?.commission_quota || 0,
          },
        ),
      );
    } catch (error) {
      showError(t('执行失败'));
    } finally {
      setSettlementLoading(false);
    }
  }

  useEffect(() => {
    const currentInputs = {};
    for (let key in props.options) {
      if (Object.keys(inputs).includes(key)) {
        currentInputs[key] = props.options[key];
      }
    }
    setInputs(currentInputs);
    setInputsRow(structuredClone(currentInputs));
    refForm.current.setValues(currentInputs);
  }, [props.options]);
  return (
    <>
      <Spin spinning={loading}>
        <Form
          values={inputs}
          getFormApi={(formAPI) => (refForm.current = formAPI)}
          style={{ marginBottom: 15 }}
        >
          <Form.Section text={t('额度设置')}>
            <Row gutter={16}>
              <Col xs={24} sm={12} md={8} lg={8} xl={8}>
                <Form.InputNumber
                  label={t('新用户初始额度')}
                  field={'QuotaForNewUser'}
                  step={1}
                  min={0}
                  suffix={'Token'}
                  placeholder={''}
                  onChange={(value) =>
                    setInputs({
                      ...inputs,
                      QuotaForNewUser: String(value),
                    })
                  }
                />
              </Col>
              <Col xs={24} sm={12} md={8} lg={8} xl={8}>
                <Form.InputNumber
                  label={t('请求预扣费额度')}
                  field={'PreConsumedQuota'}
                  step={1}
                  min={0}
                  suffix={'Token'}
                  extraText={t('请求结束后多退少补')}
                  placeholder={''}
                  onChange={(value) =>
                    setInputs({
                      ...inputs,
                      PreConsumedQuota: String(value),
                    })
                  }
                />
              </Col>
              <Col xs={24} sm={12} md={8} lg={8} xl={8}>
                <Form.InputNumber
                  label={t('邀请新用户奖励额度')}
                  field={'QuotaForInviter'}
                  step={1}
                  min={0}
                  suffix={'Token'}
                  extraText={''}
                  placeholder={t('例如：2000')}
                  onChange={(value) =>
                    setInputs({
                      ...inputs,
                      QuotaForInviter: String(value),
                    })
                  }
                />
              </Col>
            </Row>
            <Row>
              <Col xs={24} sm={12} md={8} lg={8} xl={6}>
                <Form.InputNumber
                  label={t('新用户使用邀请码奖励额度')}
                  field={'QuotaForInvitee'}
                  step={1}
                  min={0}
                  suffix={'Token'}
                  extraText={''}
                  placeholder={t('例如：1000')}
                  onChange={(value) =>
                    setInputs({
                      ...inputs,
                      QuotaForInvitee: String(value),
                    })
                  }
                />
              </Col>
              <Col xs={24} sm={12} md={8} lg={8} xl={6}>
                <Form.InputNumber
                  label={t('默认邀请日消耗提成比例')}
                  field={'AffCommissionPercentage'}
                  step={1}
                  min={0}
                  max={100}
                  suffix={'%'}
                  extraText={t(
                    '当用户没有单独设置提成比例时，按邀请用户每日消耗额度使用这里的默认值',
                  )}
                  placeholder={t('例如：10')}
                  onChange={(value) =>
                    setInputs({
                      ...inputs,
                      AffCommissionPercentage: String(value ?? 1),
                    })
                  }
                />
              </Col>
            </Row>
            <Row>
              <Col>
                <Form.Switch
                  label={t('对免费模型启用预消耗')}
                  field={'quota_setting.enable_free_model_pre_consume'}
                  extraText={t(
                    '开启后，对免费模型（倍率为0，或者价格为0）的模型也会预消耗额度',
                  )}
                  onChange={(value) =>
                    setInputs({
                      ...inputs,
                      'quota_setting.enable_free_model_pre_consume': value,
                    })
                  }
                />
              </Col>
            </Row>

            <Row>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <Button size='default' onClick={onSubmit}>
                  {t('保存额度设置')}
                </Button>
                <Popconfirm
                  title={t('确认手动执行昨日返佣结算？')}
                  content={t(
                    '将立即结算昨天的邀请日消耗返佣，重复执行不会重复发放。',
                  )}
                  onConfirm={triggerYesterdayAffSettlement}
                >
                  <Button loading={settlementLoading} type='primary'>
                    {t('手动结算昨日返佣')}
                  </Button>
                </Popconfirm>
              </div>
            </Row>
          </Form.Section>
        </Form>
      </Spin>
    </>
  );
}
